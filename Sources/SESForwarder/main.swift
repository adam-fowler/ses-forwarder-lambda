import AWSLambdaEvents
import AWSLambdaRuntime
import AsyncHTTPClient
import Foundation
import NIO
import SotoServices

Lambda.run { context in
    SESForwarderHandler(context: context)
}

struct SESForwarderHandler: EventLoopLambdaHandler {
    typealias In = AWSLambdaEvents.SES.Event
    typealias Out = Void

    struct Configuration: Codable {
        let fromAddress: String
        let forwardMapping: [String: [String]]
        let blockSpam: Bool?
    }

    enum Error: Swift.Error, CustomStringConvertible {
        case messageFileIsEmpty(String)
        case noFromAddress
        case noMessageFolderEnvironmentVariable
        case invalidMessageFolder
        case noConfigFileEnvironmentVariable
        case invalidConfigFilePath
        case configFileReadFailed

        var description: String {
            switch self {
            case .messageFileIsEmpty(let messageId):
                return "File for message: \(messageId) is empty"
            case .noFromAddress:
                return "Message did not contain a from address"
            case .invalidMessageFolder:
                return "Environment variable SES_FORWARDER_FOLDER is invalid should be of form \"s3://bucket/path\""
            case .noMessageFolderEnvironmentVariable:
                return "Environment variable SES_FORWARDER_FOLDER does not exists"
            case .noConfigFileEnvironmentVariable:
                return "Environment variable SES_FORWARDER_CONFIG does not exists"
            case .invalidConfigFilePath:
                return "Environment variable SES_FORWARDER_CONFIG is invalid should be of form \"s3://bucket/path\""
            case .configFileReadFailed:
                return "Failed to load config file"
            }
        }
    }

    let awsClient: AWSClient
    let s3: SotoServices.S3
    let ses: SotoServices.SES
    let configurationLoadingTask: Task<Configuration, Swift.Error>
    let tempS3MessageFolder: S3Folder?

    init(context: Lambda.InitializationContext) {
        self.awsClient = AWSClient(credentialProvider: .selector(.environment, .configFile()))
        self.s3 = .init(client: awsClient)
        self.ses = .init(client: awsClient)

        self.tempS3MessageFolder = Lambda.env("SES_FORWARDER_FOLDER").map { S3Folder(url: $0) } ?? nil

        let s3 = self.s3
        self.configurationLoadingTask = Task {
            try await Self.loadConfiguration(s3: s3, logger: context.logger)
        }
    }

    func shutdown(context: Lambda.ShutdownContext) -> EventLoopFuture<Void> {
        try? awsClient.syncShutdown()
        return context.eventLoop.makeSucceededFuture(())
    }

    static func loadConfiguration(s3: SotoServices.S3, logger: Logger) async throws -> Configuration {
        guard let configFile = Lambda.env("SES_FORWARDER_CONFIG") else {
            throw Error.noConfigFileEnvironmentVariable
        }
        guard let s3Path = S3Folder(url: configFile) else {
            throw Error.invalidConfigFilePath
        }

        let response = try await s3.getObject(bucket: s3Path.bucket, key: s3Path.path, logger: logger)
        let body = try await response.body.collect(upTo: 1_000_000)
        return try JSONDecoder().decode(Configuration.self, from: body)
    }

    /// Get email content from S3
    /// - Parameter messageId: message id (also S3 file name)
    /// - Returns: EventLoopFuture which will be fulfulled with email content
    func fetchEmailContents(messageId: String, s3Folder: S3Folder, logger: Logger) async throws -> ByteBuffer {
        let object = try await self.s3.getObject(bucket: s3Folder.bucket, key: s3Folder.path + messageId, logger: logger)
        let body = try await object.body.collect(upTo: 10_000_000)
        return body
    }

    /// Edit email headers, so we are allowed to forward this email on.
    ///
    /// - Parameters:
    ///   - emailData: original email data
    /// - Throws: noFromAddress
    /// - Returns: processed email data
    func processEmail(email emailData: ByteBuffer, configuration: Configuration) async throws -> ByteBuffer {
        // split email into headers and body
        let email = String(buffer: emailData)
        var headerEndIndex = email.startIndex
        email.enumerateLines { line in
            if line.count == 0 {
                headerEndIndex = line.startIndex
                return false
            }
            return true
        }
        let header = email[email.startIndex..<headerEndIndex]

        // process header
        var newHeader: String = ""
        var fromAddress: Substring.SubSequence? = nil
        var foundReplyTo: Bool = false
        header.enumerateLines { line in
            let headerField = line.headerField().lowercased()
            switch headerField {
            // SES does not allow sending messages from unverified addresses so we have to replace
            // the message's From: header with the from address in the configuration
            case "from":
                // we know there is a colon so can force this
                let headerFieldBody = line.headerFieldBody()!
                fromAddress = headerFieldBody
                // now see if we can replace email address from address of format "name <email@email.com>"
                var newFromAddress = String(headerFieldBody)
                if var emailAddressStart = newFromAddress.firstIndex(of: "<"),
                    let emailAddressEnd = newFromAddress[emailAddressStart..<newFromAddress.endIndex].firstIndex(of: ">")
                {
                    emailAddressStart = newFromAddress.index(after: emailAddressStart)
                    newFromAddress.replaceSubrange(emailAddressStart..<emailAddressEnd, with: configuration.fromAddress)
                } else {
                    newFromAddress = configuration.fromAddress
                }
                newHeader += "From: \(newFromAddress)\r\n"
            // remove return-path, sender and message-id headers
            case "return-path", "sender", "message-id":
                break
            // flag if we have found a reply-to header
            case "reply-to":
                foundReplyTo = true
                newHeader += "\(line)\r\n"
            default:
                // remove all dkim-signature headers to prevent triggering of an InvalidParameterValue error. Given we
                // have edited the headers these signatures are almost certain to be invalid
                if !headerField.contains("dkim-signature") {
                    newHeader += "\(line)\r\n"
                }
            }
            return true
        }
        if !foundReplyTo {
            guard let fromAddress = fromAddress else { throw Error.noFromAddress }
            newHeader += "Reply-To:\(fromAddress)\r\n"
        }

        // construct email from new header plus original body
        let newEmail = newHeader + email[headerEndIndex..<email.endIndex]
        return ByteBuffer(string: newEmail)
    }

    /// Get list of recipients to forward email to
    /// - Parameter message: SES message
    /// - Returns: returns list of recipients to forward email to
    func getRecipients(message: AWSLambdaEvents.SES.Message, configuration: Configuration) -> [String] {
        let list = message.receipt.recipients.reduce([String]()) {
            if let newRecipients = configuration.forwardMapping[$1.lowercased()] {
                return $0 + newRecipients
            }
            return $0
        }
        return list
    }

    /// Send email to list of recipients
    /// - Parameters:
    ///   - data: Raw email data
    ///   - from: From address
    ///   - recipients: List of recipients
    /// - Returns: EventLoopFuture that'll be fulfilled when the email has been sent
    func sendEmail(email: ByteBuffer, from: String, recipients: [String], logger: Logger) async throws {
        _ = try await ses.sendRawEmail(
            destinations: recipients,
            rawMessage: .init(data: .data(email.readableBytesView)),
            source: from,
            logger: logger
        )
    }

    /// handle one message
    /// - Parameters:
    ///   - context: Lambda context
    ///   - message: SES message
    /// - Returns: EventLoopFuture for when email is sent
    func handleMessage(context: Lambda.Context, message: AWSLambdaEvents.SES.Message, configuration: Configuration) async throws {
        guard let tempS3MessageFolder = self.tempS3MessageFolder else {
            throw Error.invalidMessageFolder
        }
        let recipients = getRecipients(message: message, configuration: configuration)
        guard recipients.count > 0 else { return }

        context.logger.info("Email from \(message.mail.commonHeaders.from) to \(message.receipt.recipients)")
        context.logger.info("Subject \(message.mail.commonHeaders.subject ?? "")")
        if message.receipt.spamVerdict.status == .fail, configuration.blockSpam == true {
            context.logger.info("Email is spam do not forward")
            return
        }
        context.logger.info("Fetch email with message id \(message.mail.messageId)")

        let email = try await fetchEmailContents(
            messageId: message.mail.messageId,
            s3Folder: tempS3MessageFolder,
            logger: context.logger
        )
        let processedEmail = try await self.processEmail(email: email, configuration: configuration)

        context.logger.info("Send email to \(recipients)")
        try await self.sendEmail(email: processedEmail, from: configuration.fromAddress, recipients: recipients, logger: context.logger)

    }

    /// Called by Lambda run. Calls `handleMessage` for each message in the supplied event
    func handle(context: Lambda.Context, event: In) -> EventLoopFuture<Void> {
        let promise = context.eventLoop.makePromise(of: Void.self)
        promise.completeWithTask {
            let configuration = try await configurationLoadingTask.value
            try await withThrowingTaskGroup(of: Result<Void, Swift.Error>.self) { group in
                for record in event.records {
                    group.addTask {
                        do {
                            return .success(try await handleMessage(context: context, message: record.ses, configuration: configuration))
                        } catch {
                            return .failure(error)
                        }
                    }
                }
                var results: [Result<Void, Swift.Error>] = .init()
                while let result = try await group.next() {
                    results.append(result)
                }
                for result in results {
                    try result.get()
                }
            }
        }
        return promise.futureResult
    }
}
