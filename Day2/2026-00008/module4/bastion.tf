###############################################################################
# Bastion: Windows에서 불가능한 docker build/push + helm/kubectl 작업 수행
###############################################################################

# Worker 이미지용 ECR
resource "aws_ecr_repository" "worker" {
  name                 = "skills-sqs-worker"
  force_delete         = true
  image_tag_mutability = "MUTABLE"
}

# Bastion에 앱 빌드 컨텍스트 전달용 S3
resource "aws_s3_bucket" "bastion" {
  bucket        = "skills-sqs-bastion-${data.aws_caller_identity.m4.account_id}"
  force_destroy = true
}

resource "aws_s3_object" "worker_app" {
  for_each = toset(["Dockerfile", "worker.py", "requirements.txt"])
  bucket   = aws_s3_bucket.bastion.id
  key      = "app/module4/${each.value}"
  source   = "${path.module}/../app/module4/${each.value}"
  etag     = filemd5("${path.module}/../app/module4/${each.value}")
}

# Bastion IAM (ECR push + EKS admin(kubectl) + EC2 tag + S3)
resource "aws_iam_role" "bastion" {
  name = "skills-sqs-bastion-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy" "bastion" {
  name = "skills-sqs-bastion-policy"
  role = aws_iam_role.bastion.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["ecr:*"], Resource = "*" },
      { Effect = "Allow", Action = ["eks:DescribeCluster", "eks:ListClusters"], Resource = "*" },
      { Effect = "Allow", Action = ["ec2:DescribeSubnets", "ec2:DescribeVpcs", "ec2:CreateTags"], Resource = "*" },
      { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"], Resource = [aws_s3_bucket.bastion.arn, "${aws_s3_bucket.bastion.arn}/*"] }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "skills-sqs-bastion-profile"
  role = aws_iam_role.bastion.name
}

# 사설 엔드포인트가 켜져 있으면 VPC 내부 DNS가 EKS API를 사설 ENI(10.4.x.x)로 해석하는데,
# Bastion은 클러스터 SG 소속이 아니라 443이 막혀 kubectl이 타임아웃된다.
# → 클러스터 SG에 VPC 내부(=Bastion) 443 인바운드를 허용.
resource "aws_vpc_security_group_ingress_rule" "bastion_to_eks_api" {
  security_group_id = aws_eks_cluster.m4.vpc_config[0].cluster_security_group_id
  cidr_ipv4         = aws_vpc.m4.cidr_block
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "Allow in-VPC (bastion) access to EKS API server"
}

# Bastion에 kubectl(EKS) 관리자 접근 부여
resource "aws_eks_access_entry" "bastion" {
  cluster_name  = aws_eks_cluster.m4.name
  principal_arn = aws_iam_role.bastion.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "bastion" {
  cluster_name  = aws_eks_cluster.m4.name
  principal_arn = aws_iam_role.bastion.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope { type = "cluster" }
  depends_on = [aws_eks_access_entry.bastion]
}

data "aws_ami" "al2023_oregon" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.1-x86_64"]
  }
}

resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.al2023_oregon.id
  instance_type               = "t3.small"
  subnet_id                   = aws_subnet.m4_public[0].id
  iam_instance_profile        = aws_iam_instance_profile.bastion.name
  associate_public_ip_address = true

  user_data = base64encode(templatefile("${path.module}/setup.sh.tpl", {
    region             = "us-west-2"
    cluster            = aws_eks_cluster.m4.name
    account_id         = data.aws_caller_identity.m4.account_id
    ecr_repo_url       = aws_ecr_repository.worker.repository_url
    cluster_endpoint   = aws_eks_cluster.m4.endpoint
    keda_role_arn      = aws_iam_role.m4_keda.arn
    karpenter_role_arn = aws_iam_role.m4_karpenter.arn
    worker_role_arn    = aws_iam_role.m4_worker.arn
    node_role_name     = aws_iam_role.m4_node.name
    sqs_url            = aws_sqs_queue.m4.url
    s3_bucket          = aws_s3_bucket.bastion.bucket
  }))

  # setup.sh(user_data) 변경 시 인스턴스를 재생성하여 부트스트랩을 다시 실행
  user_data_replace_on_change = true

  tags = { Name = "skills-sqs-bastion" }

  depends_on = [
    aws_eks_fargate_profile.m4_kube_system,
    aws_eks_fargate_profile.m4_keda,
    aws_eks_fargate_profile.m4_karpenter,
    aws_eks_access_policy_association.bastion,
    aws_iam_openid_connect_provider.m4,
    aws_s3_object.worker_app,
    aws_vpc_security_group_ingress_rule.bastion_to_eks_api,
  ]
}

# Bastion의 K8s 배포 완료 마커를 Windows에서 폴링
resource "null_resource" "bastion_wait" {
  depends_on = [aws_instance.bastion]

  # Bastion이 재생성되면(=setup.sh 변경) 폴링을 다시 수행
  triggers = {
    bastion = aws_instance.bastion.id
  }

  provisioner "local-exec" {
    interpreter = ["powershell", "-Command"]
    command     = <<-EOT
      $b = "${aws_s3_bucket.bastion.bucket}"
      for ($i=0; $i -lt 140; $i++) {
        $r = aws s3 ls "s3://$b/done/module4" --region us-west-2 2>$null
        if ($r) { Write-Host "module4 K8s ready"; exit 0 }
        Start-Sleep -Seconds 15
      }
      Write-Host "timeout waiting for module4 - bastion 로그 확인:"
      aws s3 cp "s3://$b/log/module4-setup.log" - --region us-west-2 2>$null | Select-Object -Last 40
      exit 0
    EOT
  }
}
