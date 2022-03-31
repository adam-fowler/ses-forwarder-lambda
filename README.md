# SES Forwarder Lambda

AWS Lambda for forwarding email sent to SES managed domain written in Swift. 

## Setup

### Domain verification

If you haven't done already ensure you have verified your domain in SES and setup an MX record in the DNS entry for your domain. Go to the SES dashboard select "Manage Identies" and then click on the "Verify a new domain" button at the top of the screen. This will guide you through the process. If your domain is managed by Route53 it will even add the DNS records for you. If using Route53 there is also a tickbox to add an MX record. If this isn't possible you should add a MX record to your DNS entry and point it to `10 inbound-smtp.<region>.amazonaws.com`, replacing `<region>` with the region you want to setup SES in.

## Building the Lambda

You need Docker installed on your mac before you can continue. You can find installation details [here](https://docs.docker.com/docker-for-mac/install/). Then to build your Lambda you just need to run the script `./scripts/build-and-package.sh`.

### Configuration

The Lambda uses the configuration file `config/ses-forwarder-configuration.json` to setup the Lambda. It contains three fields. 
- `fromAddress`: the address that will be used as the from address in your forwarded emails. 
- `forwardMapping`: defines where to forward emails to. Each map entry includes the original email and then an array of emails addresses you want to forward to.
- `recipientFilter`: Email filter to apply before running lambda. This is an array of email addresses or domains.

## Installation

### CDK (Cloud Development Kit)

I have written CDK scripts to setup everything. You can find them in the `cdk` folder. They pretty much do everything detailed below. You can find out more about CDK [here](https://docs.aws.amazon.com/cdk/latest/guide/home.html).

Before installing the lambda you need to edit the recipient filter to include the email addresses you want to forward email for. Open `cdk/lib/ses-forwarder-stack.ts` and edit the variable `recipientFilter`. Once you have done this you can install everything by running the following commands in your shell
```
cd cdk
cdk deploy
```
The script does the following
1) Create a S3 bucket for storing configuration and to store messages in temporarily
2) Setup lifecycle rule on bucket so messages are only kept for 30 days
3) Setup policy on bucket so SES can access it
4) Create a IAM policy for the Lambda that allows it to send raw emails and access the messages folder in the S3 bucket
5) Create Lambda function from packaged Lambda we have already created
6) Add SES receipt rule set to save files to S3 bucket and then run Lambda

Once the script has deployed you need to go to the AWS SES Console, select Rule Sets, select the Rule set `SesForwarderLambda` and press `Set as Active Rule Set`. You now have a running email forwarder.

If you would rather manually setup everything you can follow the direction below

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

## Policy

Before we install the lambda we need to setup its configuration. There are two files that need to be edited. The lambda policy `scripts/policy.json` and the file `ses-forwarder-configuration.json`. The configuration file should be uploaded to an accessible point in S3. 

In the lambda policy replace the string `<region>` for the region everything will be running in, `<account#>` for your AWS account number, `<s3bucket>` for the S3 bucket you are saving emails to and `<s3folderprefix>` for the S3 bucket prefix you add to emails saved. You need to ensure this policy gives you access to your configuration json file also.

## Uploading

Before continuing you will need the AWS command line interface installed. You can install `awscli` with Homebrew.
```
brew install awscli
```

There are four stages to getting the Lambda installed. I have collated all of these into a series of shell scripts, which are a mixture of my own work and bastardised versions of the scripts to be found in the [swift-aws-lambda-runtime](https://github.com/swift-server/swift-aws-lambda-runtime/tree/master/Examples/LambdaFunctions/scripts) repository.

If you just want the Lambda function installed and don't care about the details, just run the install script which runs all the stages.
```
./script/install.sh
```
The install process can be broken into four stages.
1) Compile the code. First part of `scripts/build-and-package.sh`
2) Package the compiled Lambda into a zip with required runtime libraries. Second part of `scripts/build-and-package.sh`
3) Deploy the packaged Lambda. `deploy.sh`
4) Go to console and edit environment variables for the Lambda. Set SES_FORWARDER_CONFIG to point to configuration json file you uploaded to S3. Path should be of the format `s3://bucket/key`.
5) Add environment variable SES_FORWARDER_FOLDER to point to the folder where SES is saving messages.

If this is the first time you are running the install, the `deploy.sh` script will create a new IAM role, add the policy document `policy.json` to the role and create a new Lambda function. Otherwise it will just update the already created Lambda.

## Run Lambda rule

Go back to your SES dashboard, and edit the receipt rule you setup earlier. Add a new action after the S3 bucket save action. Select "Lambda" and then select Lambda function "swift-ses-forwarder". Save the rule and test your newly uploaded Lambda.

## Acknowledgements

I wrote this Lambda as a replacement for the Node js version https://github.com/arithmetric/aws-lambda-ses-forwarder and much of the code is based on that.
