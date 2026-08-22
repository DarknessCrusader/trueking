#!/bin/bash

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "ACCOUNT ID: $ACCOUNT_ID"
aws configure set region ap-northeast-2
aws eks update-kubeconfig --region ap-northeast-2 --name wskorea26-cluster 2>/dev/null

# 사전 변수 할당
CF_ID=$(aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='wskorea26-concert-cf'].Id | [0]" --output text)
CF_DOMAIN=$(aws cloudfront get-distribution --id $CF_ID --query "Distribution.DomainName" --output text)
BUCKET=$(aws s3api list-buckets --query "Buckets[?starts_with(Name, 'wskorea26-concert-bucket-')].Name | [0]" --output text)
ALB_ARN=$(aws elbv2 describe-load-balancers --names wskorea26-book-alb --query "LoadBalancers[0].LoadBalancerArn" --output text)
ALB_DNS=$(aws elbv2 describe-load-balancers --names wskorea26-book-alb --query "LoadBalancers[0].DNSName" --output text)
LISTENER_ARN=$(aws elbv2 describe-listeners --load-balancer-arn $ALB_ARN --query "Listeners[0].ListenerArn" --output text)

# 1-1-A Resources CIDR
echo ====================
echo "  1-1-A Resources CIDR"
echo ====================
aws ec2 describe-vpcs --filter Name=tag:Name,Values=wskorea26-vpc --query "Vpcs[0].CidrBlock" --output text && aws ec2 describe-subnets --filters "Name=tag:Name,Values=wskorea26-pub-subnet-c,wskorea26-pub-subnet-d,wskorea26-priv-subnet-c,wskorea26-priv-subnet-d" --query "sort_by(Subnets,&Tags[?Key=='Name']|[0].Value)[].[Tags[?Key=='Name']|[0].Value,CidrBlock]" --output text

# 1-2-A Routing Tables
echo ====================
echo "  1-2-A Routing Tables"
echo ====================
for subnet in wskorea26-pub-subnet-c wskorea26-pub-subnet-d; do aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=$subnet" --query "Subnets[0].SubnetId" --output text)" --query "RouteTables[0].Tags[?Key=='Name']|[0].Value" --output text; done | sort; for subnet in wskorea26-priv-subnet-c wskorea26-priv-subnet-d; do aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=$subnet" --query "Subnets[0].SubnetId" --output text)" --query "RouteTables[0].Tags[?Key=='Name']|[0].Value" --output text; done | sort; aws ec2 describe-route-tables --filters "Name=tag:Name,Values=wskorea26-public-rtb" --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].GatewayId | [0]" --output text; for rtb in wskorea26-private-rtb-c wskorea26-private-rtb-d; do aws ec2 describe-route-tables --filters "Name=tag:Name,Values=$rtb" --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].NatGatewayId | [0]" --output text; done

# 2-1-A S3 Bucket & Objects
echo ====================
echo "  2-1-A S3 Bucket & Objects"
echo ====================
echo $BUCKET && aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "web/main/" --query "sort(Contents[].Key)" --output text

# 2-2-A S3 Configuration
echo ====================
echo "  2-2-A S3 Configuration"
echo ====================
for key in web/main/index.html web/main/main.jpeg; do kms_arn=$(aws s3api head-object --bucket "$BUCKET" --key "$key" --query "SSEKMSKeyId" --output text); key_id=$(echo "$kms_arn" | awk -F'/' '{print $NF}'); aws kms list-aliases --query "Aliases[?TargetKeyId=='$key_id'].AliasName | [0]" --output text; done; aws s3api get-public-access-block --bucket "$BUCKET" --query "PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]" --output text; aws s3api get-bucket-policy-status --bucket "$BUCKET" --query "PolicyStatus.IsPublic" --output text

# 3-1-A ECR Repository & Image
echo ====================
echo "  3-1-A ECR Repository & Image"
echo ====================
aws ecr describe-repositories --query "repositories[?repositoryName=='wskorea26-book-repo'].[repositoryName,imageScanningConfiguration.scanOnPush,encryptionConfiguration.encryptionType]" --output text
aws ecr describe-images --repository-name wskorea26-book-repo --image-ids imageTag=stable --query "imageDetails[0].imageTags" --output text
SCAN_RESULT=$(aws ecr describe-image-scan-findings --repository-name wskorea26-book-repo --image-id imageTag=stable --output json)
if [ $? -ne 0 ]; then
  echo '{"SCAN_STATUS":"ERROR"}'
else
  SCAN_STATUS=$(echo "$SCAN_RESULT" | jq -r '.imageScanStatus.status // "UNKNOWN"')
  FINDING_COUNTS=$(echo "$SCAN_RESULT" | jq '.imageScanFindings.findingSeverityCounts // {}')
  if [ "$SCAN_STATUS" != "COMPLETE" ]; then
    printf '{"SCAN_STATUS":"%s"}\n' "$SCAN_STATUS"
  elif [ "$(echo "$FINDING_COUNTS" | jq 'length')" -eq 0 ]; then
    printf '{\n  "LOW": 0\n}\n'
  else
    echo "$FINDING_COUNTS"
  fi
fi

# 4-1-A DynamoDB Configuration
echo ====================
echo "  4-1-A DynamoDB Configuration"
echo ====================
aws dynamodb describe-table --table-name wskorea26-data-table --query "Table.[TableName,KeySchema[0].[AttributeName,KeyType],DeletionProtectionEnabled]" --output text; aws kms list-aliases --query "Aliases[?TargetKeyId=='$(aws dynamodb describe-table --table-name wskorea26-data-table --query "Table.SSEDescription.KMSMasterKeyArn" --output text | awk -F'/' '{print $NF}')'].AliasName | [0]" --output text

# 5-1-A Cluster Configuration
echo ====================
echo "  5-1-A Cluster Configuration"
echo ====================
aws eks describe-cluster --name wskorea26-cluster --query "cluster.[name,version]" --output text; aws eks describe-cluster --name wskorea26-cluster --query "sort(cluster.logging.clusterLogging[?enabled==\`true\`].types[])" --output text

# 5-2-A Cluster KMS & Subnets
echo ====================
echo "  5-2-A Cluster KMS & Subnets"
echo ====================
aws kms list-aliases --query "Aliases[?TargetKeyId=='$(aws eks describe-cluster --name wskorea26-cluster --query "cluster.encryptionConfig[0].provider.keyArn" --output text | awk -F'/' '{print $NF}')'].AliasName | [0]" --output text; aws ec2 describe-subnets --subnet-ids $(aws eks describe-cluster --name wskorea26-cluster --query "cluster.resourcesVpcConfig.subnetIds[]" --output text) --query "sort(Subnets[*].Tags[?Key=='Name'].Value[])" --output text

# 5-3-A Cluster Node Configuration
echo ====================
echo "  5-3-A Cluster Node Configuration"
echo ====================
for ng in wskorea26-addon-ng wskorea26-app-ng; do
  aws eks describe-nodegroup --cluster-name wskorea26-cluster --nodegroup-name $ng --query "nodegroup.[nodegroupName,instanceTypes[0]]" --output text
done
for ng in wskorea26-addon-ng wskorea26-app-ng; do
  aws ec2 describe-subnets --subnet-ids $(aws eks describe-nodegroup --cluster-name wskorea26-cluster --nodegroup-name $ng --query "nodegroup.subnets[]" --output text) --query "sort(Subnets[*].Tags[?Key=='Name'].Value[])" --output text
done

# 5-4-A Cluster Pod Configuration
echo ====================
echo "  5-4-A Cluster Pod Configuration"
echo ====================
kubectl get namespace wskorea26 --output jsonpath='{.metadata.name}' && echo ""
addon_nodes() {
  kubectl get pods --all-namespaces -o json | jq -r '
    .items[]
    | select(.metadata.namespace != "wskorea26")
    | select((.metadata.ownerReferences // [] | map(.kind) | index("DaemonSet")) == null)
    | .spec.nodeName // empty
  '
}
app_nodes() {
  kubectl get pods -n wskorea26 -o json | jq -r '
    .items[]
    | select((.metadata.ownerReferences // [] | map(.kind) | index("DaemonSet")) == null)
    | .spec.nodeName // empty
  '
}
for node in $(addon_nodes); do
  kubectl get node "$node" -o jsonpath='{.metadata.labels.node-type}{"\n"}'
done | sort -u
for node in $(app_nodes); do
  kubectl get node "$node" -o jsonpath='{.metadata.labels.node-type}{"\n"}'
done | sort -u

# 6-1-A Function Configuration
echo ====================
echo "  6-1-A Function Configuration"
echo ====================
aws lambda get-function-configuration --function-name wskorea26-book-lambda --query "[FunctionName,Runtime,Environment.Variables.TABLE_NAME]" --output text

# 7-1-A ALB Configuration
echo ====================
echo "  7-1-A ALB Configuration"
echo ====================
aws elbv2 describe-load-balancers --names wskorea26-book-alb --query "LoadBalancers[0].[LoadBalancerName,Scheme]" --output text; aws elbv2 describe-listeners --load-balancer-arn $ALB_ARN --query "Listeners[0].[Port,Protocol]" --output text

# 7-2-A ALB Rules Configuration
echo ====================
echo "  7-2-A ALB Rules Configuration"
echo ====================
aws elbv2 describe-rules --listener-arn $LISTENER_ARN --query "Rules[*].Conditions[*].HttpHeaderConfig.Values[]" --output text; curl -o /dev/null -s -w "%{http_code}\n" http://$ALB_DNS/book

# 8-1-A Distribution Configuration
echo ====================
echo "  8-1-A Distribution Configuration"
echo ====================
aws cloudfront get-distribution --id $CF_ID --query "Distribution.[DomainName,Status]" --output text

# 8-2-A Origin Configuration
echo ====================
echo "  8-2-A Origin Configuration"
echo ====================
aws cloudfront get-distribution --id $CF_ID --query "Distribution.DistributionConfig.Origins.Items[].[Id,DomainName]" --output text

# 8-3-A Cache Behaviors
echo ====================
echo "  8-3-A Cache Behaviors"
echo ====================
aws cloudfront get-distribution --id $CF_ID --query "Distribution.DistributionConfig.[DefaultCacheBehavior.TargetOriginId,CacheBehaviors.Items[?PathPattern=='/book*' || PathPattern=='/book'].TargetOriginId|[0],DefaultCacheBehavior.ViewerProtocolPolicy]" --output text

# 8-4-A Origin Custom Headers
echo ====================
echo "  8-4-A Origin Custom Headers"
echo ====================
aws cloudfront get-distribution --id $CF_ID --query "Distribution.DistributionConfig.Origins.Items[].CustomHeaders.Items[].[HeaderName,HeaderValue]" --output text

# 8-5-A Static Web Hosting
echo ====================
echo "  8-5-A Static Web Hosting"
echo ====================
curl -o /dev/null -s -w "%{http_code}\n" https://$CF_DOMAIN; curl -o /dev/null -s -w "%{http_code}\n" http://$CF_DOMAIN/; curl -o /dev/null -s -w "status: %{http_code}, size: %{size_download} bytes\n" https://$CF_DOMAIN/main.jpeg

# 9-1-A App Test (POST)
echo ====================
echo "  9-1-A App Test (POST)"
echo ====================
curl -s -X POST -H 'Content-Type: application/json' -d '{"client_id":"D1114","username":"akane","email":"akane@ztmy.com","concert_name":"ZUTOMAYO_INTENSE_II"}' https://$CF_DOMAIN/book

# 9-2-A App Test (GET 200)
echo ====================
echo "  9-2-A App Test (GET 200)"
echo ====================
echo ""
curl -s -X GET -H 'Content-Type: application/json' "https://$CF_DOMAIN/book?concert_name=ZUTOMAYO_INTENSE_II"
echo

# 9-3-A App Test (GET 400)
echo ====================
echo "  9-3-A App Test (GET 400)"
echo ====================
echo ""
curl -s -o /dev/null -w "%{http_code}\n" -X GET -H 'Content-Type: application/json' "https://$CF_DOMAIN/book"

# 10-0 Monitoring Configure (사전 준비)
echo ====================
echo "  10-0 Monitoring Configure <수동채점>"
echo ====================
aws elbv2 describe-load-balancers --names wskorea26-grafana-alb --query "LoadBalancers[0].DNSName" --output text
echo "Login: skills-<비번호>-admin / \$korea26!!"
echo "Dashboard: wskorea26-monitoring"
echo "Manual Marking: 10-1 ~ 10-4"
echo "접속 안될 경우 url에 http:// 와 :80 을 붙혀 재시도"
