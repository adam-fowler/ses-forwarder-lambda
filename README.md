# SES Forwarder Lambda

AWS Lambda for forwarding email sent to SES managed domain written in Swift. 

## Setup

### Domain verification

If you haven't done already ensure you have verified your domain in SES and setup an MX record in the DNS entry for your domain. Go to the SES dashboard select "Manage Identies" and then click on the "Verify a new domain" button at the top of the screen. This will guide you through the process. If your domain is managed by Route53 it will even add the DNS records for you. Although you should make sure you have ticked the box to include the MX record.

### Rule sets

Now you can send email to SES using your domain. At this point though all email sent to your domain is bounced back. You need to add some receipt rules to manage what happens to the email. On the mail SES screen click on "Rule Sets" and then click on the "Create a Receipt Rule" button. Add the reciepients for who you want to forward email. On the next page you manage the actions applied to an email. Options include "S3", "SNS", "SQS", "Lambda", "WorkMail". At this point we will add the action "S3". This saves emails to an S3 bucket. You may need to add permissions to your S3 bucket for this to work. Add the following to the bucket policy. Replacing `<bucket>` for your s3 bucket name and `<acccount#>` for you account number.
```
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "SESForwarder",
            "Effect": "Allow",
            "Principal": {
                "Service": "ses.amazonaws.com"
            },
            "Action": "s3:PutObject",
            "Resource": "arn:aws:s3:::<bucket>/*",
            "Condition": {
                "StringEquals": {
                    "aws:Referer": "<account#>"
                }
            }
        }
    ]
}
```
Once we have deployed the ses-forwarder-lambda we will return here to add another rule to invoke the lambda. 

## Configuration

Before we install the lambda we need to setup its configuration. There are two files that need to be edited. The lambda policy `scripts/policy.json` and the file `ses-forwarder-configuration.json`. 

In the `ses-forwarder-configuration.json` file you need to set the S3 path `s3Folder` for where messages will be stored. Ensure this is the same as was setup in your SES receipt rule. The address `fromAddress` that will be used as the from address in your forwarded emails. The email forwarding map `forwardMapping`. Each map entry includes the original email and then an array of emails addresses you want to forward to. Upload this file to an accessible point in S3.

In the lambda policy replace the string `<region>` for the region everything will be running in, `<account#>` for your AWS account number, `<s3bucket>` for the S3 bucket you are saving emails to and `<s3folderprefix>` for the S3 bucket prefix you add to emails saved. You need to ensure this policy gives you access to your configuration json file also.

## Building and installation

Before continuing you will need [Docker Desktop for Mac](https://docs.docker.com/docker-for-mac/install/) installed. You will also need the AWS command line interface installed. You can install `awscli` with Homebrew.
```
brew install awscli
```

There are four stages to getting the Lambda installed. I have collated all of these into a series of shell scripts, which are a mixture of my own work and bastardised versions of the scripts to be found in the [swift-aws-lambda-runtime](https://github.com/swift-server/swift-aws-lambda-runtime/tree/master/Examples/LambdaFunctions/scripts) repository.

If you just want the Lambda function installed and don't care about the details, just run the install script which runs all the stages.
```
./script/install.sh
```
The install process can be broken into four stages.
1) Build a Docker image for building the Lambda. `scripts/build-lambda-builder.sh`
2) Compile the code. First part of `scripts/build-and-package.sh`
3) Package the compiled Lambda into a zip with required runtime libraries. Second part of `scripts/build-and-package.sh`
4) Deploy the packaged Lambda. `deploy.sh`
5) Go to console and edit environment variables for the Lambda. Set SES_FORWARDER_CONFIG to point to configuration json file you uploaded to S3. Path should be of the format `s3://bucket/key`.

If this is the first time you are running the install, the `deploy.sh` script will create a new IAM role, add the policy document `policy.json` to the role and create a new Lambda function. Otherwise it will just update the already created Lambda.

## Run Lambda rule

Go back to your SES dashboard, and edit the receipt rule you setup earlier. Add a new action after the S3 bucket save action. Select "Lambda" and then select Lambda function "swift-ses-forwarder". Save the rule and test your newly uploaded Lambda.

## Acknowledgements

I wrote this Lambda as a replacement for the Node js version https://github.com/arithmetric/aws-lambda-ses-forwarder and much of the code is based on that.
