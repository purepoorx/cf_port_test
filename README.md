# Cloudflare 端口测试工具 (cf-port-test)

这是一个简单的 Web 服务，用于测试指定的网络端口是否可以通过 Cloudflare 或其他代理正常访问。

它的核心功能是：当您访问服务器的某个端口时，它会通过 HTTP 响应将该端口号返回给您。例如，访问 `http://your.domain:8080` 会返回文本 `8080`。

该项目使用 Go 语言编写后端服务，并使用 Nginx 作为反向代理来监听多个端口。

## 特性

- **多端口监听**: 支持通过 Nginx 同时监听多个 HTTP 和 HTTPS 端口。
- **端口回显**: 访问任何已配置的端口，都会返回对应的端口号。
- **多域名支持**: 支持通过 Let's Encrypt 的 SAN 证书为多个域名提供 HTTPS 服务。
- **交互式管理脚本**: 提供一个用户友好的交互式脚本 (`install.sh`)，引导您完成安装或卸载。
- **CI/CD 集成**: 通过 GitHub Actions 实现自动化编译和发布。

## 自动化流程

本项目的管理分为两个主要阶段：CI（持续集成）和 CD（持续部署/管理）。

### 1. CI: 自动编译和发布 (GitHub Actions)

当您向本仓库的 `v*` 格式的标签（例如 `v1.0.1`, `v1.2.0`）推送代码时，预先配置好的 GitHub Actions 工作流 (`.github/workflows/release.yml`) 会被自动触发。

该工作流会：
1.  检出最新的代码。
2.  设置 Go 语言环境。
3.  将 Go 程序编译为适用于 Linux 的二进制文件 `cfporttest`。
4.  创建一个新的 GitHub Release，并将编译好的 `cfporttest` 文件作为产物 (Asset) 上传。

您需要做的仅仅是完成开发后，为您的提交打上一个新的 `v*` 标签并推送到 GitHub。

```bash
# 例如，创建一个 v1.0.0 的发布
git tag v1.0.0
git push origin v1.0.0
```

### 2. CD: 在服务器上使用交互式脚本

在您的目标服务器上，您只需要运行一个交互式脚本即可完成所有部署和卸载工作。

**前提条件**:
- 您的服务器是一台主流的 Linux 发行版（如 Ubuntu, Debian, CentOS）。
- 您拥有 `sudo` 权限。
- 您要使用的域名已经全部解析到该服务器的公网 IP 地址。

**使用步骤**:

1.  **下载并授权**:
    从本仓库下载 `install.sh` 脚本到您的服务器，并赋予它执行权限。
    ```bash
    curl -L -o install.sh https://raw.githubusercontent.com/purepoorx/cf_port_test/main/install.sh
    chmod +x install.sh
    ```

2.  **运行脚本**:
    使用 `sudo` 权限运行脚本，它会引导您完成后续操作。
    ```bash
    sudo ./install.sh
    ```
    脚本会首先询问您是想 **安装/更新** 还是 **卸载** 应用。

    -   **如果选择安装**: 脚本会提示您输入域名、邮箱和可选的版本号，然后自动完成所有部署工作。
    -   **如果选择卸载**: 脚本会提示您输入需要卸载的域名，并询问是否要彻底清除 Nginx 和 Certbot，然后完成所有清理工作。