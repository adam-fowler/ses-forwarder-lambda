
extension SESForwarderHandler {
    struct Configuration {
        static let fromAddress: String = "noreply@example.com"
        static let subjectPrefix: String = ""
        static let forwardMapping: [String: [String]] = [
            "test@example.com": ["test@example2.com"]
        ]
        static let s3Bucket: String = "example"
        static let s3KeyPrefix: String = "temp/email/"
        static let snsTopic: String? = nil
    }
}
