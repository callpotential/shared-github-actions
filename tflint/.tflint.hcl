config {
    module = true

#    ignore_module = {
#        "terraform-aws-modules/vpc/aws"            = true
#        "terraform-aws-modules/security-group/aws" = true
#    }
}

plugin "aws" {
    enabled = true
    deep_check = true

    version = "0.21.0"
    source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
