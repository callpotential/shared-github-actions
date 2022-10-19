# S3 & Cloudfront Deployment Composite Actions

These actions will help you get Frontend deployments up on S3 & Cloudfront.

## s3-publish-build
inputs:
```
  service-name:
    required: true
    description: Forms the base of the packaged zip file, likely `app-name`-ui
  dist-dir:
    required: true
    description: Directory where app build assets are created
  aws-region:
    required: false
    default: 'us-east-1'
    description: region for AWS operations
  aws-access-key-id:
    required: true
    description: Access Key of user to login as
  aws-secret-access-key:
    required: true
    description: Secret Access key of user to login as
  aws-role:
    required: true
    description: Role to assume to deploy package
  builds-bucket-name:
    required: true
    description: Bucket name for deployed packages
```
This action should be used in your **code repo**, only **on pushes to master**. It will take a built `dist` dir, package it up, and place the built package with proper naming and tagging into the provided builds bucket. <br />
**Note:** This action should be called twice, once configured for your app on ninja, and again configured for prod!<br />
**Note:** You can get the `aws-role` from the output of your `*-infra` repo, after it runs the TF Apply and exports the TF variables to the run log.

## s3-deploy
inputs:
```
  aws-access-key-id:
    required: true
    description: AWS Access key id for authentication
  aws-secret-access-key:
    required: true
    description: AWS Secret Access key for authentication
  aws-region:
    required: false
    description: AWS region
    default: us-east-1
  deploy-if-unchanged:
    required: false
    description: Force deploy even if no changes detected
    default: 'false'
```
This action should be used in your **infra repo**. It will take the outputs from the Terraform run and perform the deployment actions for the environment.json and code package if needed.

## s3-pr-deploy
inputs:
```
  dist-dir:
    required: true
    description: Directory where app build assets are created
  aws-region:
    required: false
    default: 'us-east-1'
    description: region for AWS operations
  aws-access-key-id:
    required: true
    description: Access Key of user to login as
  aws-secret-access-key:
    required: true
    description: Secret Access key of user to login as
  aws-role:
    required: true
    description: Role to assume to deploy files
  docroots-bucket-name:
    required: true
    description: Bucket name for deployed files
  subdomain:
    required: false
    description: (optional) subdomain to publish to. Generated from PR ref name by default
  base-url:
    required: true
    description: base url for the service. e.g. "home.terminusplatform.ninja"
  app-name:
    required: false
    description: for repos with multiple repos, set this to differentiate the GH deployments
```
This action should be used in your **code repo** for **pushes to PRs** labelled with `preview-deploy`. This will take your **development build** files from the specified `dist/` folder and publish them under a subdomain in your ninja environment. The subdomain will by default be computed from the branch name, but can be specified via an input if something custom is needed.
