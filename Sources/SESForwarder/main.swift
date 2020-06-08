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

        var description: String {
            switch self {
            case .messageFileIsEmpty(let messageId):
                return "File for message: \(messageId) is empty"
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

    func fetchEmailContents(messageId: String) -> EventLoopFuture<Data> {
        return s3.getObject(.init(bucket: Configuration.s3Bucket, key: Configuration.s3KeyPrefix + messageId))
            .flatMapThrowing { response in
                guard let body = response.body?.asData() else { throw Error.messageFileIsEmpty(messageId) }
                return body
        }
    }
    
    /*func processEmail(email: Data, recipientMap: [String: String]) -> Data {
        
    }*/
    
    func calculateRecipientMap(payload: SES.Message) -> [String: [String]] {
        var map: [String: [String]] = [:]
        payload.receipt.recipients.forEach {
            guard let newRecipient = Configuration.forwardMapping[$0.lowercased()] else { return }
            map[$0] = newRecipient
        }
        return map
    }
    
    func handle(context: Lambda.Context, payload: In) -> EventLoopFuture<Void> {
        return fetchEmailContents(messageId: payload.records[0].ses.mail.messageId)
            .map { body in
                if let text = String(bytes: body, encoding: .utf8) {
                    print(text)
                }
        }
        .map { _ in }
    }
}
