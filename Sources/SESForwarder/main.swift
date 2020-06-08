import AsyncHTTPClient
import AWSLambdaEvents
import AWSLambdaRuntime
import AWSS3
import AWSSES
import Foundation
import NIO

#if DEBUG
try Lambda.withLocalServer {
    Lambda.run { eventLoop in
        return SESForwarderHandler(eventLoop: eventLoop)
    }
}
#else
Lambda.run { eventLoop in
    return SESForwarderHandler(eventLoop: eventLoop)
}
#endif

class SESForwarderHandler: EventLoopLambdaHandler {
    typealias In = SES.Event
    typealias Out = Void

    enum Error: Swift.Error, CustomStringConvertible {
        case messageFileIsEmpty(String)
        case noFromAddress

        var description: String {
            switch self {
            case .messageFileIsEmpty(let messageId):
                return "File for message: \(messageId) is empty"
            case .noFromAddress:
                return "Message did not contain a from address"
            }
        }
    }

    let httpClient: HTTPClient
    let s3: AWSS3.S3
    let ses: AWSSES.SES

    init(eventLoop: EventLoop) {
        self.httpClient = HTTPClient(eventLoopGroupProvider: .shared(eventLoop))
        self.s3 = .init(region: .euwest1, httpClientProvider: .shared(self.httpClient))
        self.ses = .init(region: .euwest1, httpClientProvider: .shared(self.httpClient))
    }
    
    deinit {
        try? httpClient.syncShutdown()
    }
    
    /// Get email content from S3
    /// - Parameter messageId: message id (also S3 file name)
    /// - Returns: EventLoopFuture which will be fulfulled with email content
    func fetchEmailContents(messageId: String) -> EventLoopFuture<Data> {
        return s3.getObject(.init(bucket: Configuration.s3Bucket, key: Configuration.s3KeyPrefix + messageId))
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
    func processEmail(email emailData: Data) throws -> Data {
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
                    newFromAddress.replaceSubrange(emailAddressStart..<emailAddressEnd, with: Configuration.fromAddress)
                } else {
                    newFromAddress = Configuration.fromAddress
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
    func getRecipients(message: SES.Message) -> [String] {
        let list = message.receipt.recipients.reduce([String]()) {
            if let newRecipients = Configuration.forwardMapping[$1.lowercased()] {
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
    func sendEmail(data: Data, from: String, recipients: [String]) -> EventLoopFuture<Void> {
        let request = AWSSES.SES.SendRawEmailRequest(destinations: recipients, rawMessage: .init(data: data), source: from)
        return ses.sendRawEmail(request).map { _ in }
    }
    
    /// handle one message
    /// - Parameters:
    ///   - context: Lambda context
    ///   - message: SES message
    /// - Returns: EventLoopFuture for when email is sent
    func handleMessage(context: Lambda.Context, message: SES.Message) -> EventLoopFuture<Void> {
        let recipients = getRecipients(message: message)
        guard recipients.count > 0 else { return context.eventLoop.makeSucceededFuture(())}
        
        return fetchEmailContents(messageId: message.mail.messageId)
            .flatMapThrowing { email in
                return try self.processEmail(email: email)
        }
        .flatMap { email in
            return self.sendEmail(data: email, from: Configuration.fromAddress, recipients: recipients)
        }
        .map { _ in }
    }
    
    /// Called by Lambda run. Calls handle message for each message in the supplied payload
    func handle(context: Lambda.Context, payload: In) -> EventLoopFuture<Void> {
        let returnFutures: [EventLoopFuture<Void>] = payload.records.map { return handleMessage(context: context, message: $0.ses) }
        return EventLoopFuture.whenAllComplete(returnFutures, on: context.eventLoop).map { _ in }
    }
}
