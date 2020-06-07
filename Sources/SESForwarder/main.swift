import AWSLambdaEvents
import AWSLambdaRuntime
import NIO
import AsyncHTTPClient
import AWSS3
import AWSSES

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

    func fetchMessage(messageId: String) -> EventLoopFuture<ByteBuffer> {
        
    }
    
    func handle(context: Lambda.Context, payload: In) -> EventLoopFuture<Void> {
        return context.eventLoop.makeSucceededFuture(())
    }
}
