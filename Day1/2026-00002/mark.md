====================
  1-1-A Resources CIDR
====================
172.16.0.0/16
wskorea26-priv-subnet-c 172.16.201.0/24
wskorea26-priv-subnet-d 172.16.202.0/24
wskorea26-pub-subnet-c  172.16.1.0/24
wskorea26-pub-subnet-d  172.16.2.0/24
====================
  1-2-A Routing Tables
====================
wskorea26-public-rtb
wskorea26-public-rtb
wskorea26-private-rtb-c
wskorea26-private-rtb-d
igw-0f9cf166ea442338c
nat-0bef73cb0516704da
nat-073007be0cb81d196
====================
  2-1-A S3 Bucket & Objects
====================
wskorea26-concert-bucket-117
web/main/index.html     web/main/main.jpeg
====================
  2-2-A S3 Configuration
====================
alias/wskorea26-s3-key
alias/wskorea26-s3-key
True    True    True    True
False
====================
  3-1-A ECR Repository & Image
====================
wskorea26-book-repo     True    KMS
stable
null
====================
  4-1-A DynamoDB Configuration
====================
wskorea26-data-table    True
client_id       HASH
alias/wskorea26-dynamodb-key
====================
  5-1-A Cluster Configuration
====================
wskorea26-cluster       1.35
api     audit   authenticator   controllerManager       scheduler
====================
  5-2-A Cluster KMS & Subnets
====================
alias/wskorea26-eks-key
wskorea26-priv-subnet-c wskorea26-priv-subnet-d
====================
  5-3-A Cluster Node Configuration
====================
wskorea26-addon-ng      t3.medium       wskorea26-addon-node
wskorea26-app-ng        t3.medium       wskorea26-app-node
wskorea26-priv-subnet-c wskorea26-priv-subnet-d
wskorea26-priv-subnet-c wskorea26-priv-subnet-d
====================
  5-4-A Cluster Pod Configuration
====================
wskorea26
addon
app
====================
  6-1-A Function Configuration
====================
wskorea26-book-lambda   python3.14      wskorea26-data-table
====================
  7-1-A ALB Configuration
====================
wskorea26-book-alb      internet-facing
80      HTTP
====================
  7-2-A ALB Rules Configuration
====================
wskorea26-cf
wskorea26-cf
403
====================
  8-1-A Distribution Configuration
====================
d20g6qwaz4ultn.cloudfront.net   Deployed
====================
  8-2-A Origin Configuration
====================
wskorea26-alb-origin    wskorea26-book-alb-487163787.ap-northeast-2.elb.amazonaws.com
wskorea26-s3-origin     wskorea26-concert-bucket-117.s3.ap-northeast-2.amazonaws.com
====================
  8-3-A Cache Behaviors
====================
wskorea26-s3-origin     wskorea26-alb-origin    redirect-to-https
====================
  8-4-A Origin Custom Headers
====================
X-Origin-Verify wskorea26-cf
wskorea26-s3-access     true
====================
  8-5-A Static Web Hosting
====================
200
301
status: 200, size: 180926 bytes
====================
  9-1-A App Test (POST)
====================
{"booking_id":"D0ACX0C8"}
====================
  9-2-A App Test (GET 200)
====================

[{"username": "akaね", "created_at": "2026-07-17T15:04:20+09:00", "email": "akane@ztmy.com", "booking_id": "D0ACX0C8", "client_id": "D1114", "concert_name": "ZUTOMAYO_INTENSE_II"}]
====================
  9-3-A App Test (GET 400)
====================
400
====================
  10-1 Monitoring Configure (수동)
====================
URL: http://wskorea26-grafana-alb-78425382.ap-northeast-2.elb.amazonaws.com/d/wskorea26/wskorea26-monitoring
Login: skills-<비번호>-admin / $korea26!!
Manual Marking
