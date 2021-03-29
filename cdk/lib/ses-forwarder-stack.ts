import { App, Construct, Duration, Stack, StackProps } from "@aws-cdk/core";
import * as lambda from "@aws-cdk/aws-lambda";
import * as iam from "@aws-cdk/aws-iam";
import * as s3 from "@aws-cdk/aws-s3";
import * as s3Deploy from "@aws-cdk/aws-s3-deployment";
import * as ses from "@aws-cdk/aws-ses";
import * as sesActions from "@aws-cdk/aws-ses-actions";
import * as path from "path";
import { toComputedKey } from "@babel/types";

const messageFolder = "messages/"
const recipientFilter = ["email.com"]

export class SesForwarderLambdaStack extends Stack {
  private bucket: s3.Bucket

  constructor(scope: Construct, id: string, props?: StackProps) {
    super(scope, id, props);

    // S3 bucket
    this.bucket = new s3.Bucket(this, "SesForwarderBucket", {
      lifecycleRules: [
        {
          prefix: messageFolder,
          expiration: Duration.days(30),
          enabled: true,
          id: "DeleteMessagesAfter30Days"
        }
      ]
    })

    // s3 bucket policy statements
    const saveToS3Policy = new iam.PolicyStatement()
    saveToS3Policy.addPrincipals(new iam.ServicePrincipal("ses.amazonaws.com"))
    saveToS3Policy.addActions("s3:PutObject")
    saveToS3Policy.addResources(this.bucket.bucketArn + "/*")
    saveToS3Policy.addCondition("StringEquals", {"aws:Referer": this.account})

    const bucketPolicy = new s3.BucketPolicy(this, "SesForwarderBucketPolicy", {
      bucket: this.bucket
    })
    bucketPolicy.document.addStatements(saveToS3Policy)

    // deploy ses forwarder config file to s3 bucket
    new s3Deploy.BucketDeployment(this, "DeployConfiguration", {
      sources: [s3Deploy.Source.asset("../config")],
      destinationBucket: this.bucket
    })

    // lambda policy statements
    const sendEmailPolicy = new iam.PolicyStatement()
    sendEmailPolicy.addActions("ses:SendRawEmail")
    sendEmailPolicy.addResources("*")
    const readS3BucketPolicy = new iam.PolicyStatement()
    readS3BucketPolicy.addActions("s3:GetObject")
    readS3BucketPolicy.addResources(this.bucket.bucketArn + "/*")

    // docker file 
    const zipfile = path.join(__dirname, "../../.build/lambda/SESForwarder/lambda.zip")
    // create lambda
    const lambdaFunction = new lambda.Function(this, "SesForwarderLambda", {
      code: lambda.Code.fromAsset(zipfile),
      handler: "swift-ses-forwarder",
      runtime: lambda.Runtime.PROVIDED,
      memorySize: 192,
      initialPolicy: [sendEmailPolicy, readS3BucketPolicy],
      environment: {
        "SES_FORWARDER_CONFIG": "s3://" + this.bucket.bucketName + "/ses-forwarder-configuration.json",
        "SES_FORWARDER_FOLDER": "s3://" + this.bucket.bucketName + "/" + messageFolder
      }
    })

    // Add SES receipt rule set
    const receiptRules = new ses.ReceiptRuleSet(this, "SesForwarderReceiptRules", {
      dropSpam: false,
      receiptRuleSetName: "SesForwarderLambda",
      rules: [
        {
          recipients: recipientFilter,
          scanEnabled: true,
          actions: [
            new sesActions.S3({
              bucket: this.bucket,
              objectKeyPrefix: messageFolder
            }),
            new sesActions.Lambda({
              function: lambdaFunction,
              invocationType: sesActions.LambdaInvocationType.EVENT
            })
          ]             
        }
      ]
    })
  }
}
