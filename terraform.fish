#! /opt/homebrew/bin/fish

set backend_args \
    -backend-config="bucket=lcm-s3-terraform-state" \
    -backend-config="key=bioinfo-computed.tfstate"

switch $argv[1]
  case init
    echo "Running terraform init..."
    terraform -chdir="terraform" init $backend_args

  case plan
    echo "Running terraform plan..."
    terraform -chdir="terraform" plan

  case apply
    echo "Running terraform apply..."
    terraform -chdir="terraform" apply

  case destroy
    echo "Running terraform destroy..."
    terraform -chdir="terraform" destroy

  case '*'
    echo "Usage: ./terraform.fish {init|plan|apply}"
    exit 1
end
