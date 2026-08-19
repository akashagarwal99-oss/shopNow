terraform {
  required_version = ">= 1.11.0"

  # This bucket is NOT created by this Terraform config (a backend can't create the bucket it
  # then needs to store its own state in). Create it once, by hand, before `terraform init` —
  # the account ID is baked into the name so it's globally unique without having to guess:
  #   aws s3api create-bucket --bucket akash-shopnow-tfstate-655383751644 --region ap-south-1 \
  #     --create-bucket-configuration LocationConstraint=ap-south-1
  #   aws s3api put-bucket-versioning --bucket akash-shopnow-tfstate-655383751644 \
  #     --versioning-configuration Status=Enabled
  #   aws s3api put-bucket-encryption --bucket akash-shopnow-tfstate-655383751644 \
  #     --server-side-encryption-configuration \
  #     '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  #   aws s3api put-public-access-block --bucket akash-shopnow-tfstate-655383751644 \
  #     --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  #
  # The "shopnow/dev/" prefix in the key below is deliberate, not decorative — it leaves room for
  # a second environment (e.g. "shopnow/staging/terraform.tfstate") to share the same bucket with
  # a different key later, without colliding.
  backend "s3" {
    bucket       = "akash-shopnow-tfstate-655383751644"
    key          = "shopnow/dev/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true # native S3 locking (Terraform >= 1.11) — no DynamoDB table needed
  }
}
