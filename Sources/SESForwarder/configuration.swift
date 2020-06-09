
extension SESForwarderHandler {
    struct Configuration {
        static let fromAddress: String = "noreply@example.com"
        static let subjectPrefix: String = ""
        static let forwardMapping: [String: [String]] = [
            "john@example.com": ["john@example2.com"],
            "bill@example.com": ["bill@example2.com"],
            "admin@example.com": ["bill@example2.com", "john@example2.com"],
        ]
        static let s3Bucket: String = "example"
        static let s3KeyPrefix: String = "temp/email/"
        static let snsTopic: String? = nil
    }
}
