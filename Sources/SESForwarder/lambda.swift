import AsyncHTTPClient
import AWSLambdaEvents
import AWSLambdaRuntime
import SotoS3
import SotoSES
import Foundation
import NIO

@main
final class SESForwarderHandler: LambdaHandler {
    typealias Event = SESEvent
    typealias Output = Void

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
    let s3: S3
    let ses: SES
    var configuration: Configuration?
    let tempS3MessageFolder: S3Folder?

    init(context: LambdaInitializationContext) {
        self.awsClient = AWSClient(
            credentialProvider: .selector(.environment, .configFile()), 
            httpClientProvider: .createNewWithEventLoopGroup(context.eventLoop)
        )
        self.s3 = .init(client: awsClient)
        self.ses = .init(client: awsClient)
        self.tempS3MessageFolder = Lambda.env("SES_FORWARDER_FOLDER").map { S3Folder(url: $0) } ?? nil
        self.configuration = nil//try await self.loadConfiguration(logger: context.logger)
        
        context.terminator.register(name: "AWSClient") { eventLoop in
            try? self.awsClient.syncShutdown()
            return eventLoop.makeSucceededFuture(())
        }
    }
    
    func loadConfiguration(logger: Logger) async throws -> Configuration {
        guard let configFile = Lambda.env("SES_FORWARDER_CONFIG") else {
            throw Error.noConfigFileEnvironmentVariable
        }
        guard let s3Path = S3Folder(url: configFile) else {
            throw Error.invalidConfigFilePath
        }

        let response = try await self.s3.getObject(.init(bucket: s3Path.bucket, key: s3Path.path), logger: logger)
        guard let body = response.body?.asByteBuffer() else { throw Error.configFileReadFailed }
        return try self.decoder.decode(Configuration.self, from: body)
    }

    /// Get email content from S3
    /// - Parameter messageId: message id (also S3 file name)
    /// - Returns: EventLoopFuture which will be fulfulled with email content
    func fetchEmailContents(messageId: String, s3Folder: S3Folder, logger: Logger) async throws -> Data {
        let response = try await s3.getObject(.init(bucket: s3Folder.bucket, key: s3Folder.path + messageId), logger: logger)
        guard let body = response.body?.asData() else { throw Error.messageFileIsEmpty(messageId) }
        return body
    }
    
    /// Edit email headers, so we are allowed to forward this email on.
    ///
    /// - Parameters:
    ///   - emailData: original email data
    /// - Throws: noFromAddress
    /// - Returns: processed email data
    func processEmail(email emailData: Data, configuration: Configuration) throws -> Data {
        // split email into headers and body
        let email = String(decoding: emailData, as: Unicode.UTF8.self)
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
                    let emailAddressEnd = newFromAddress[emailAddressStart..<newFromAddress.endIndex].firstIndex(of: ">") {
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
        return Data(newEmail.utf8)
    }
    
    /// Get list of recipients to forward email to
    /// - Parameter message: SES message
    /// - Returns: returns list of recipients to forward email to
    func getRecipients(message: SESEvent.Message, configuration: Configuration) -> [String] {
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
    func sendEmail(data: Data, from: String, recipients: [String], logger: Logger) async throws {
        let request = SES.SendRawEmailRequest(destinations: recipients, rawMessage: .init(data: data), source: from)
        _ = try await ses.sendRawEmail(request, logger: logger)
    }
    
    /// handle one message
    /// - Parameters:
    ///   - context: Lambda context
    ///   - message: SES message
    /// - Returns: EventLoopFuture for when email is sent
    func handleMessage(context: LambdaContext, message: AWSLambdaEvents.SESEvent.Message, configuration: Configuration) async throws {
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

        let newEmail = try self.processEmail(email: email, configuration: configuration)

        context.logger.info("Send email to \(recipients)")
        return try await self.sendEmail(data: newEmail, from: configuration.fromAddress, recipients: recipients, logger: context.logger)
    }
    
    /// Called by Lambda run. Calls `handleMessage` for each message in the supplied event
    func handle(_ event: Event, context: LambdaContext) async throws -> Output {
        // is this the first time. Load the configuration file
        if self.configuration == nil {
            self.configuration = try await self.loadConfiguration(logger: context.logger)
        }
        for record in event.records {
            try await handleMessage(context: context, message: record.ses, configuration: self.configuration!)
        }
    }
}
