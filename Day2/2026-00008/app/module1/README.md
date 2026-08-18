# Module 1 DocumentDB Client Application

이 디렉터리는 2과제 1모듈 DocumentDB NoSQL 문제에서 선수에게 제공하는 Client Application 파일입니다.

## 고정 동작 값

`docdb_client.py`는 아래 값을 소스코드 내 고정값으로 사용합니다.

- AWS Region: `ap-northeast-2`
- Secret Name: `skills-nosql-docdb-secret`
- Database Name: `skills_retail`
- DocumentDB Port: `27017`
- DocumentDB TLS: `true`
- Client Application Listen Address: `0.0.0.0`
- Client Application Listen Port: `8080`
- Dataset Path: `/opt/skills-nosql/retail_dataset.json`
- TLS CA Bundle Path: `/opt/skills-nosql/global-bundle.pem`

## Secret JSON

Secrets Manager Secret `skills-nosql-docdb-secret`은 아래 Key만 필수로 포함합니다.

```json
{
  "username": "<DocumentDB username>",
  "password": "<DocumentDB password>",
  "host": "<DocumentDB cluster endpoint hostname>"
}
```

`host` 값에는 `https://`, `mongodb://`, `:27017` 등을 포함하지 않고 DocumentDB Cluster Endpoint hostname만 입력합니다.

`port`, `database`, `tls`, `dbname`, `engine` 등은 Secret에 넣지 않습니다. 제공 Client Application은 해당 값을 사용하지 않습니다.

## 설치

```bash
chmod +x install_client_app.sh
sudo ./install_client_app.sh
```

## 실행

```bash
/opt/skills-nosql/run_app.sh
```

운영 중에는 systemd, nohup, tmux 등 원하는 방식으로 계속 실행되도록 구성합니다.

## 데이터 적재

Client Application이 실행 중인 상태에서 다음을 실행합니다.

```bash
/opt/skills-nosql/run_seed.sh
```

`run_seed.sh`는 데이터만 적재하며 Index 또는 TTL Index를 생성하지 않습니다. Index와 TTL Index는 문제 요구사항에 따라 선수가 직접 구성해야 합니다.

## 검증

```bash
/opt/skills-nosql/run_validate.sh
```
