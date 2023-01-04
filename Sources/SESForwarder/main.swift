import AsyncHTTPClient
import AWSLambdaEvents
import AWSLambdaRuntime
import SotoServices
import Foundation
import NIO

Lambda.run { context in
    return SESForwarderHandler(context: context)
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

    let httpClient: HTTPClient
    let awsClient: AWSClient
    let s3: SotoServices.S3
    let ses: SotoServices.SES
    let configPromise: EventLoopPromise<Configuration>
    let tempS3MessageFolder: S3Folder?

    init(context: Lambda.InitializationContext) {
        self.httpClient = HTTPClient(eventLoopGroupProvider: .shared(context.eventLoop))
        self.awsClient = AWSClient(credentialProvider: .selector(.environment, .configFile()), httpClientProvider: .shared(httpClient))
        self.s3 = .init(client: awsClient)
        self.ses = .init(client: awsClient)
        self.configPromise = context.eventLoop.makePromise(of: Configuration.self)

        self.tempS3MessageFolder = Lambda.env("SES_FORWARDER_FOLDER").map { S3Folder(url: $0) } ?? nil

        loadConfiguration(logger: context.logger, on: context.eventLoop).cascade(to: self.configPromise)
    }
    
    func shutdown(context: Lambda.ShutdownContext) -> EventLoopFuture<Void> {
        try? awsClient.syncShutdown()
        try? httpClient.syncShutdown()
        return context.eventLoop.makeSucceededFuture(())
    }

    func loadConfiguration(logger: Logger, on eventLoop: EventLoop) -> EventLoopFuture<Configuration> {
        guard let configFile = Lambda.env("SES_FORWARDER_CONFIG") else {
            return eventLoop.makeFailedFuture(Error.noConfigFileEnvironmentVariable)
        }
        guard let s3Path = S3Folder(url: configFile) else {
            return eventLoop.makeFailedFuture(Error.invalidConfigFilePath)
        }

        return self.s3.getObject(.init(bucket: s3Path.bucket, key: s3Path.path), logger: logger).flatMapThrowing { response -> Configuration in
            guard let body = response.body?.asByteBuffer() else { throw Error.configFileReadFailed }
            return try self.decoder.decode(Configuration.self, from: body)
        }
    }

    /// Get email content from S3
    /// - Parameter messageId: message id (also S3 file name)
    /// - Returns: EventLoopFuture which will be fulfulled with email content
    func fetchEmailContents(messageId: String, s3Folder: S3Folder, logger: Logger) -> EventLoopFuture<Data> {
        return s3.getObject(.init(bucket: s3Folder.bucket, key: s3Folder.path + messageId), logger: logger)
            .flatMapThrowing { response in
                guard let body = response.body?.asData() else { throw Error.messageFileIsEmpty(messageId) }
                return body
        }
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
    func sendEmail(data: Data, from: String, recipients: [String], logger: Logger) -> EventLoopFuture<Void> {
        let request = SotoServices.SES.SendRawEmailRequest(destinations: recipients, rawMessage: .init(data: .data(data)), source: from)
        return ses.sendRawEmail(request, logger: logger).map { _ in }
    }
    
    /// handle one message
    /// - Parameters:
    ///   - context: Lambda context
    ///   - message: SES message
    /// - Returns: EventLoopFuture for when email is sent
    func handleMessage(context: Lambda.Context, message: AWSLambdaEvents.SES.Message, configuration: Configuration) -> EventLoopFuture<Void> {
        guard let tempS3MessageFolder = self.tempS3MessageFolder else {
            return context.eventLoop.makeFailedFuture(Error.invalidMessageFolder)
        }
        let recipients = getRecipients(message: message, configuration: configuration)
        guard recipients.count > 0 else { return context.eventLoop.makeSucceededFuture(())}
        
        context.logger.info("Email from \(message.mail.commonHeaders.from) to \(message.receipt.recipients)")
        context.logger.info("Subject \(message.mail.commonHeaders.subject ?? "")")
        if message.receipt.spamVerdict.status == .fail, configuration.blockSpam == true {
            context.logger.info("Email is spam do not forward")
            return context.eventLoop.makeSucceededVoidFuture()
        }
        context.logger.info("Fetch email with message id \(message.mail.messageId)")

        return fetchEmailContents(
            messageId: message.mail.messageId,
            s3Folder: tempS3MessageFolder,
            logger: context.logger
        ).flatMapThrowing { email in
            return try self.processEmail(email: email, configuration: configuration)
        }
        .flatMap { email -> EventLoopFuture<Void> in
            context.logger.info("Send email to \(recipients)")
            return self.sendEmail(data: email, from: configuration.fromAddress, recipients: recipients, logger: context.logger)
        }
    }
    
    /// Called by Lambda run. Calls `handleMessage` for each message in the supplied event
    func handle(context: Lambda.Context, event: In) -> EventLoopFuture<Void> {
        configPromise.futureResult.flatMap { configuration in
            let returnFutures: [EventLoopFuture<Void>] = event.records.map {
                handleMessage(context: context, message: $0.ses, configuration: configuration)
            }
            return EventLoopFuture.whenAllSucceed(returnFutures, on: context.eventLoop).map { _ in }
        }
    }
}
