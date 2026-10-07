# tag-snyk-scan

Terraform-provisioned AWS Lambda infrastructure with automated Snyk
Infrastructure as Code (IaC) security scanning, GitHub Actions CI/CD
pipelines, OIDC-federated AWS authentication, AWS STS temporary
credentials, and encrypted Amazon S3 remote state.

The project demonstrates a security-gated Infrastructure as Code
deployment workflow in which Terraform configuration is validated and
scanned before merge, while deployments from the protected `main` branch
authenticate to AWS through GitHub OIDC federation rather than
persistent AWS access keys.

------------------------------------------------------------------------

## Architecture

``` text
Developer
    │
    ▼
Feature Branch
    │
    ▼
Pull Request
    │
    ├── terraform-checks
    │     ├── terraform fmt -check -recursive
    │     ├── terraform init -backend=false
    │     └── terraform validate
    │
    └── snyk-checks
          └── snyk iac test .
                │
                ▼
         Required Checks Pass
                │
                ▼
        Protected main Branch
                │
                ▼
        GitHub Actions CD
                │
                ▼
         GitHub OIDC Token
                │
                ▼
              AWS STS
      AssumeRoleWithWebIdentity
                │
                ▼
       IAM Deployment Role
                │
                ▼
             Terraform
        ┌───────┴────────┐
        ▼                ▼
 Amazon S3           AWS APIs
 Remote State            │
                         ▼
                     AWS Lambda
                         │
                  ┌──────┴──────┐
                  ▼             ▼
             CloudWatch       X-Ray
```

### Deployment Path

`Feature Branch` → `Pull Request` → `Terraform Validation` →
`Snyk IaC Scan` → `Protected main` → `GitHub Actions CD` → `GitHub OIDC`
→ `AWS STS` → `IAM Deployment Role` → `Terraform` → `AWS Lambda`

------------------------------------------------------------------------

## Infrastructure Components

The Terraform configuration provisions and manages the following AWS
resources:

  -----------------------------------------------------------------------
  Component               Implementation          Purpose
  ----------------------- ----------------------- -----------------------
  Compute                 AWS Lambda              Executes the serverless
                                                  Python workload

  Runtime                 Python 3.13             Lambda application
                                                  runtime

  IAM                     Lambda execution role   Provides runtime
                                                  permissions to the
                                                  Lambda function

  Logging                 Amazon CloudWatch Logs  Receives Lambda
                                                  execution logs

  Tracing                 AWS X-Ray               Provides active
                                                  distributed tracing

  State                   Amazon S3               Persists Terraform
                                                  remote state

  Authentication          GitHub OIDC + AWS STS   Provides keyless CI/CD
                                                  authentication

  CI/CD                   GitHub Actions          Performs validation,
                                                  security scanning, and
                                                  deployment

  IaC Security            Snyk IaC                Detects Terraform
                                                  security
                                                  misconfigurations

  IaC                     Terraform               Defines and reconciles
                                                  AWS infrastructure
  -----------------------------------------------------------------------

------------------------------------------------------------------------

## Terraform Infrastructure

### AWS Provider

The AWS provider is configured for `us-east-1` and applies common tags
to Terraform-managed resources.

``` hcl
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "tag-snyk-scan"
      ManagedBy = "Terraform"
    }
  }
}
```

The AWS region is parameterized through:

``` hcl
variable "aws_region" {
  description = "AWS region used to deploy the Lambda function"
  type        = string
  default     = "us-east-1"
}
```

This separates environment-specific configuration from the resource
definitions.

------------------------------------------------------------------------

## Lambda Packaging

The Lambda application source is stored at:

``` text
lambda/lambda_function.py
```

Terraform uses the `archive` provider to package the Python source into
a ZIP deployment artifact:

``` hcl
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/lambda_function.py"
  output_path = "${path.module}/lambda_function.zip"
}
```

Terraform calculates the archive hash and supplies it to Lambda through:

``` hcl
source_code_hash = data.archive_file.lambda_zip.output_base64sha256
```

This allows Terraform to detect changes to the deployment package and
update the Lambda function when the source artifact changes.

The generated `lambda_function.zip` artifact is excluded from Git source
control because it is a derived build artifact.

------------------------------------------------------------------------

## AWS Lambda

The workload is deployed as:

``` text
tag-snyk-scan-hello-world
```

with:

``` hcl
resource "aws_lambda_function" "hello_world" {
  function_name = "tag-snyk-scan-hello-world"

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  role    = aws_iam_role.lambda_exec.arn
  handler = "lambda_function.lambda_handler"
  runtime = "python3.13"

  timeout     = 10
  memory_size = 128

  tracing_config {
    mode = "Active"
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_basic_execution
  ]
}
```

The function uses the handler:

``` text
lambda_function.lambda_handler
```

and returns a basic HTTP-style response:

``` python
def lambda_handler(event, context):
    print("Hello, World!")

    return {
        "statusCode": 200,
        "body": "Hello, World!"
    }
```

------------------------------------------------------------------------

## IAM Runtime Security

The Lambda function does not use the GitHub deployment role at runtime.

Instead, Terraform creates a dedicated Lambda execution role:

``` text
tag-snyk-scan-lambda-role
```

Its trust policy permits the AWS Lambda service principal to assume the
role:

``` hcl
data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}
```

Terraform attaches:

``` text
AWSLambdaBasicExecutionRole
```

to provide the baseline permissions required for Lambda logging.

This creates separation between:

``` text
GitHub deployment identity
        │
        └── provisions infrastructure

Lambda execution identity
        │
        └── executes application workload
```

The CI/CD deployment role and application runtime role therefore
represent separate IAM security boundaries.

------------------------------------------------------------------------

## AWS X-Ray Tracing

AWS X-Ray active tracing is configured directly in Terraform:

``` hcl
tracing_config {
  mode = "Active"
}
```

This control was introduced as a remediation following the initial Snyk
IaC scan.

The initial security scan identified:

``` text
SNYK-CC-TF-133
X-ray tracing is disabled for Lambda function
```

The infrastructure definition was subsequently remediated and rescanned
successfully.

This demonstrates the intended DevSecOps control loop:

``` text
IaC Definition
     │
     ▼
Security Scan
     │
     ▼
Finding Detected
     │
     ▼
Terraform Remediation
     │
     ▼
Security Re-scan
     │
     ▼
Gate Passes
     │
     ▼
Merge / Deployment
```

Security scanning therefore acts as an enforcement gate rather than a
post-deployment assessment.

------------------------------------------------------------------------

## Terraform Workflow

Terraform follows a staged infrastructure lifecycle in which
configuration is initialized, formatted, validated, planned, and applied
to the target environment:

``` text
INIT → FORMAT → VALIDATE → PLAN → APPLY
```

The lifecycle is distributed across pull-request CI and deployment CD
rather than executing every stage in a single workflow.

### 1. Initialize --- `terraform init`

``` bash
terraform init
```

`terraform init` prepares the Terraform working directory. For this
project it initializes the HashiCorp AWS and Archive providers,
processes dependency selections recorded in `.terraform.lock.hcl`,
and---during deployment---connects Terraform to the Amazon S3
remote-state backend.

Pull-request CI deliberately uses:

``` bash
terraform init -backend=false
```

This initializes the providers required for validation without giving
the PR validation job access to deployment state.

### 2. Format --- `terraform fmt`

``` bash
terraform fmt
```

`terraform fmt` rewrites Terraform configuration into canonical HCL
formatting. CI enforces formatting without modifying repository files:

``` bash
terraform fmt -check -recursive
```

`-check` causes the job to fail if formatting differs from Terraform
conventions, while `-recursive` evaluates Terraform configuration
throughout the repository.

### 3. Validate --- `terraform validate`

``` bash
terraform validate
```

`terraform validate` performs static validation after initialization. It
checks configuration syntax and internal consistency, including resource
arguments, references, variables, outputs, and provider schemas.
Validation does not create or modify AWS resources.

### 4. Plan --- `terraform plan`

``` bash
terraform plan
```

Planning evaluates the desired Terraform configuration against Terraform
state and the corresponding AWS infrastructure to calculate the required
changes.

The CD workflow creates an explicit saved plan:

``` bash
terraform plan -out=tfplan
```

Conceptually:

``` text
Terraform Configuration
          +
   S3 Remote State
          +
Current AWS Resource State
          │
          ▼
 Terraform Evaluation
          │
          ▼
        tfplan
```

The plan exposes intended operations such as resource creation,
modification, or destruction before deployment.

### 5. Apply --- `terraform apply`

``` bash
terraform apply
```

The CD pipeline applies the previously generated execution plan:

``` bash
terraform apply -auto-approve tfplan
```

Applying the saved `tfplan` ensures that the deployment executes the
evaluated plan generated in the preceding stage rather than implicitly
recalculating a different plan. After a successful apply, Terraform
updates the remote state to represent the resulting managed
infrastructure.

### Terraform Lifecycle Architecture

``` text
                TERRAFORM CONFIGURATION
                         │
                         ▼
                  terraform init
                         │
             ┌───────────┴───────────┐
             │                       │
       Initialize Providers     Initialize Backend
             │                       │
             └───────────┬───────────┘
                         ▼
                  terraform fmt
                         │
                         ▼
                Canonical HCL Format
                         │
                         ▼
                terraform validate
                         │
                         ▼
              Configuration Validity
                         │
                         ▼
                  terraform plan
                         │
              ┌──────────┼──────────┐
              ▼          ▼          ▼
        Configuration   State    AWS APIs
              │          │          │
              └──────────┼──────────┘
                         ▼
                       tfplan
                         │
                         ▼
                  terraform apply
                         │
                         ▼
                 AWS Infrastructure
                         │
                         ▼
                  S3 Remote State
```

  -------------------------------------------------------------------------------------
  Terraform Stage           Pull Request CI         Deployment CD      Function
  ---------------------- ---------------------- ---------------------- ----------------
  `terraform init`         ✓ `-backend=false`             ✓            Initialize
                                                                       Terraform,
                                                                       providers, and
                                                                       deployment
                                                                       backend

  `terraform fmt`        ✓ `-check -recursive`           ---           Enforce
                                                                       canonical HCL
                                                                       formatting

  `terraform validate`             ✓                      ✓            Validate
                                                                       configuration
                                                                       correctness

  `terraform plan`                ---              ✓ `-out=tfplan`     Calculate
                                                                       infrastructure
                                                                       changes

  `terraform apply`               ---                 ✓ `tfplan`       Execute the
                                                                       saved Terraform
                                                                       plan
  -------------------------------------------------------------------------------------

The separation is intentional: pull-request CI performs non-deploying
quality and security validation, while CD receives AWS deployment
authorization only after validated changes enter the protected `main`
branch.

------------------------------------------------------------------------

## Continuous Integration

The CI workflow is defined at:

``` text
.github/workflows/ci.yml
```

and executes for pull requests targeting:

``` text
main
```

Two independent jobs are implemented.

### `terraform-checks`

The Terraform validation job executes:

``` bash
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
```

`terraform init -backend=false` initializes Terraform providers and
modules without attempting to access the production remote-state
backend.

This enables static Terraform validation during pull-request execution
without granting the CI validation job deployment-level access to the
state backend.

### `snyk-checks`

The security job executes:

``` bash
snyk iac test .
```

Authentication is provided through the GitHub repository secret:

``` text
SNYK_TOKEN
```

Snyk evaluates the Terraform configuration for cloud infrastructure
security misconfigurations.

------------------------------------------------------------------------

## Branch Protection and Security Gates

The `main` branch is protected through GitHub repository rules.

Pull requests must satisfy the required status checks:

``` text
CI / terraform-checks
CI / snyk-checks
```

before changes can be merged.

The resulting control path is:

``` text
Code Change
    │
    ▼
Pull Request
    │
    ├── Terraform validation
    │
    └── Snyk IaC security analysis
             │
             ▼
       Required Checks
             │
      ┌──────┴──────┐
      │             │
    FAIL           PASS
      │             │
      ▼             ▼
Merge Blocked   Merge Permitted
```

This prevents infrastructure configuration that fails either the
Terraform validation gate or Snyk IaC security gate from entering the
deployment branch.

------------------------------------------------------------------------

## Continuous Deployment

The deployment workflow is defined at:

``` text
.github/workflows/cd.yml
```

The workflow executes on changes pushed to `main`, including merged pull
requests, and supports manual execution through `workflow_dispatch`.

The deployment lifecycle is:

``` text
Checkout
   │
   ▼
AWS OIDC Authentication
   │
   ▼
Terraform Setup
   │
   ▼
terraform init
   │
   ▼
terraform validate
   │
   ▼
terraform plan -out=tfplan
   │
   ▼
terraform apply -auto-approve tfplan
```

An explicit Terraform plan artifact is generated:

``` bash
terraform plan -out=tfplan
```

and the same evaluated plan is supplied to:

``` bash
terraform apply -auto-approve tfplan
```

This ensures the apply operation executes the previously generated
Terraform plan rather than implicitly recalculating the desired changes
through a separate `terraform apply` invocation.

Terraform formatting is enforced earlier by the required pull-request CI
gate through:

``` bash
terraform fmt -check -recursive
```

Accordingly, the complete Terraform lifecycle across the CI/CD
architecture is:

``` text
INIT → FORMAT → VALIDATE → PLAN → APPLY
```

CI is responsible for formatting and pre-merge validation, while CD is
responsible for remote-state initialization, deployment validation,
planning, and infrastructure application.

------------------------------------------------------------------------

## GitHub OIDC Federation

The CD workflow does not store AWS access keys.

Instead, GitHub Actions authenticates to AWS through OpenID Connect
workload identity federation.

The workflow grants:

``` yaml
permissions:
  id-token: write
  contents: read
```

`id-token: write` allows the GitHub Actions runner to request an OIDC
identity token.

AWS authentication is configured using:

``` yaml
- name: Configure AWS credentials via OIDC
  uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: ${{ secrets.OIDC_ROLE }}
    aws-region: us-east-1
```

The repository secret:

``` text
OIDC_ROLE
```

contains the ARN of the AWS IAM deployment role rather than an AWS
access key.

------------------------------------------------------------------------

## OIDC Authentication Flow

The authentication sequence is:

``` text
GitHub Actions Runner
        │
        │ Request OIDC token
        ▼
GitHub OIDC Provider
        │
        │ Signed identity token
        ▼
AWS Security Token Service
        │
        │ sts:AssumeRoleWithWebIdentity
        ▼
IAM Deployment Role
        │
        │ Temporary AWS credentials
        ▼
Terraform AWS Provider
        │
        ▼
AWS APIs
```

AWS validates the token against the configured GitHub OIDC identity
provider:

``` text
token.actions.githubusercontent.com
```

The IAM trust relationship restricts which GitHub repository and branch
identity may assume the deployment role.

AWS STS then issues temporary credentials for the workflow execution.

This removes the requirement to persist:

``` text
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
```

as GitHub repository secrets.

------------------------------------------------------------------------

## Authentication Security Model

OIDC federation provides several security properties:

-   No long-lived AWS access keys stored in GitHub.
-   AWS credentials are generated dynamically for workflow execution.
-   Credentials are short-lived.
-   AWS STS controls role assumption.
-   IAM trust conditions constrain the accepted GitHub workload
    identity.
-   Deployment authorization is separated from GitHub repository
    authentication.
-   The workflow receives AWS credentials only when the configured trust
    relationship is satisfied.

The authentication model is therefore:

``` text
Identity proof
     +
IAM trust policy
     +
STS temporary credentials
     =
Authorized CI/CD AWS session
```

------------------------------------------------------------------------

## Terraform Remote State

Terraform uses an Amazon S3 backend for persistent remote state.

The project state is namespaced under:

``` text
tag/3.6-snyk-scan/terraform.tfstate
```

with backend encryption enabled.

The backend provides persistent state independently of the GitHub-hosted
runner.

This is necessary because GitHub Actions runners are ephemeral:

``` text
Workflow Run #1
Temporary Runner
      │
      └── destroyed after execution

Workflow Run #2
New Temporary Runner
      │
      └── no previous local terraform.tfstate
```

Without remote state, subsequent workflow executions would not have a
persistent Terraform record of the previously managed infrastructure.

With S3 remote state:

``` text
GitHub Runner #1 ──┐
GitHub Runner #2 ──┼──► Amazon S3 Remote State
GitHub Runner #3 ──┘             │
                                 ▼
                     Existing Resource State
```

Terraform can therefore reconcile the desired configuration against the
infrastructure it previously provisioned.

------------------------------------------------------------------------

## S3 State Access Control

The GitHub deployment role is granted state-specific S3 permissions
rather than unrestricted S3 administrative access.

The state-access policy provides the operations required for the project
namespace, including:

``` text
s3:ListBucket
s3:GetObject
s3:PutObject
s3:DeleteObject
```

against the appropriate state bucket and project-specific state prefix.

This follows the principle of reducing the S3 authorization scope to the
Terraform state required by this workload.

------------------------------------------------------------------------

## CI/CD Security Boundaries

The repository separates validation and deployment responsibilities.

### Pull Request Context

``` text
Terraform formatting
Terraform initialization without backend
Terraform validation
Snyk IaC scanning
```

The PR workflow validates proposed infrastructure but does not deploy
it.

### Main Branch Context

``` text
OIDC authentication
AWS STS role assumption
S3 remote-state access
Terraform planning
Terraform application
AWS resource provisioning
```

Deployment occurs only after the code has entered the protected `main`
branch.

This establishes the control boundary:

``` text
Untrusted / Proposed Change
          │
          ▼
      CI Validation
          │
          ▼
    Security Gates
          │
          ▼
    Protected Merge
          │
          ▼
 Authorized Deployment
```

------------------------------------------------------------------------

## Terraform State Lifecycle

The deployment workflow consumes configuration that has already passed
the required CI formatting and validation gates. Within CD, the
state-aware deployment sequence follows:

``` text
terraform init
      │
      ├── initialize AWS provider
      ├── initialize archive provider
      └── connect to S3 backend
              │
              ▼
terraform validate
              │
              ▼
terraform plan -out=tfplan
      │
      ├── read remote state
      ├── query AWS resource state
      ├── compare desired vs actual state
      └── construct execution plan
              │
              ▼
terraform apply tfplan
      │
      ├── create
      ├── modify
      └── reconcile resources
              │
              ▼
       Updated Remote State
```

------------------------------------------------------------------------

## Deployment Verification

The deployed Lambda configuration can be inspected using:

``` bash
aws lambda get-function \
  --function-name tag-snyk-scan-hello-world \
  --region us-east-1 \
  --query 'Configuration.[FunctionName,Runtime,State,TracingConfig.Mode]' \
  --output table
```

Verified deployment:

``` text
Function    tag-snyk-scan-hello-world
Runtime     python3.13
State       Active
X-Ray       Active
```

This confirms that:

-   the Lambda function exists;
-   the expected Python runtime is configured;
-   the function is operational;
-   AWS X-Ray active tracing is enabled.

------------------------------------------------------------------------

## Lambda Functional Test

The deployed workload can be invoked using:

``` bash
aws lambda invoke \
  --function-name tag-snyk-scan-hello-world \
  --region us-east-1 \
  --payload '{}' \
  --cli-binary-format raw-in-base64-out \
  response.json
```

The response can then be inspected with:

``` bash
cat response.json
```

Expected application response:

``` json
{
  "statusCode": 200,
  "body": "Hello, World!"
}
```

------------------------------------------------------------------------

## DevSecOps Control Flow

The complete lifecycle implemented by this repository is:

``` text
                 SOURCE CONTROL
                       │
                       ▼
                Feature Branch
                       │
                       ▼
                  Pull Request
                       │
             ┌─────────┴─────────┐
             ▼                   ▼
     Terraform Checks       Snyk IaC Scan
             │                   │
             └─────────┬─────────┘
                       ▼
               Required CI Gates
                       │
                       ▼
                 Protected main
                       │
                       ▼
                GitHub Actions CD
                       │
                       ▼
                  GitHub OIDC
                       │
                       ▼
                    AWS STS
                       │
                       ▼
              IAM Deployment Role
                       │
                       ▼
                    Terraform
                 ┌─────┴─────┐
                 ▼           ▼
           S3 State        AWS APIs
                               │
                               ▼
                           AWS Lambda
                          ┌────┴────┐
                          ▼         ▼
                     CloudWatch   X-Ray
```

------------------------------------------------------------------------

## Security Controls

The implementation combines controls across source control, CI/CD, cloud
identity, infrastructure state, and runtime configuration.

### Source Control

-   Protected `main` branch
-   Pull-request-based change integration
-   Required CI status checks
-   Required Snyk IaC security gate

### CI

-   Terraform formatting validation
-   Terraform configuration validation
-   Backend-independent PR validation
-   Snyk IaC security scanning

### CD

-   Deployment only from `main`
-   Explicit Terraform plan generation
-   Plan-based Terraform apply
-   OIDC-federated AWS authentication

### Identity

-   GitHub OIDC workload identity
-   AWS STS `AssumeRoleWithWebIdentity`
-   Temporary AWS credentials
-   IAM trust-policy restrictions
-   No persistent AWS access keys in GitHub Actions

### Terraform State

-   Persistent Amazon S3 backend
-   State encryption
-   Project-specific state namespace
-   IAM-controlled state access
-   State persistence across ephemeral runners

### AWS Workload

-   Dedicated Lambda execution role
-   CloudWatch logging permissions
-   AWS X-Ray active tracing
-   Terraform-managed infrastructure configuration

------------------------------------------------------------------------

## Repository Structure

``` text
tag-snyk-scan/
├── .github/
│   └── workflows/
│       ├── ci.yml
│       └── cd.yml
├── lambda/
│   └── lambda_function.py
├── .gitignore
├── .terraform.lock.hcl
├── main.tf
├── outputs.tf
├── provider.tf
├── variables.tf
├── versions.tf
└── README.md
```

### File Responsibilities

  -----------------------------------------------------------------------
  File                                Responsibility
  ----------------------------------- -----------------------------------
  `main.tf`                           Lambda, IAM, packaging and
                                      infrastructure resources

  `provider.tf`                       AWS provider configuration and
                                      resource tagging

  `variables.tf`                      Configurable Terraform input
                                      variables

  `versions.tf`                       Terraform/provider requirements and
                                      remote backend

  `outputs.tf`                        Lambda and IAM resource outputs

  `lambda/lambda_function.py`         Python Lambda application

  `.github/workflows/ci.yml`          Terraform validation and Snyk
                                      security gates

  `.github/workflows/cd.yml`          OIDC-authenticated Terraform
                                      deployment

  `.terraform.lock.hcl`               Reproducible provider dependency
                                      selections

  `.gitignore`                        Excludes Terraform state, generated
                                      artifacts and local files
  -----------------------------------------------------------------------

------------------------------------------------------------------------

## Technology Stack

### Infrastructure as Code

`Terraform` · `HashiCorp AWS Provider` · `HashiCorp Archive Provider`

### AWS

`AWS Lambda` · `AWS IAM` · `AWS STS` · `Amazon S3` · `Amazon CloudWatch`
· `AWS X-Ray`

### DevSecOps

`GitHub Actions` · `GitHub OIDC` · `Snyk IaC` · `Protected Branches` ·
`Required Status Checks`

### Application

`Python 3.13`

------------------------------------------------------------------------

## Key DevSecOps Principles Demonstrated

This project demonstrates:

**Infrastructure as Code** --- AWS resources are declaratively defined
and lifecycle-managed through Terraform.

**Shift-left security** --- Snyk evaluates Terraform during pull-request
validation before infrastructure reaches the deployment branch.

**Security gates** --- failed Terraform or Snyk checks prevent
protected-branch integration.

**Workload identity federation** --- GitHub Actions authenticates to AWS
using OIDC rather than stored AWS access keys.

**Ephemeral credentials** --- AWS STS provides temporary credentials for
deployment execution.

**Remote state management** --- Terraform state persists in encrypted
Amazon S3 storage rather than ephemeral CI/CD runners.

**Identity separation** --- the GitHub deployment identity is distinct
from the Lambda runtime execution identity.

**Automated deployment** --- validated changes merged to `main` are
reconciled against AWS through Terraform.

**Observability as code** --- AWS X-Ray active tracing is defined in
Terraform and enforced through IaC security scanning.

**Security remediation as code** --- infrastructure security findings
are corrected in Terraform, rescanned, reviewed, and deployed through
the same controlled workflow.

**Controlled Terraform lifecycle** --- infrastructure changes progress
through `INIT → FORMAT → VALIDATE → PLAN → APPLY`, with validation
separated from deployment and the saved execution plan applied through
the protected CD path.
