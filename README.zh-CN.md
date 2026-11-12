# Rsync Rollback

[English](README.md) | [简体中文](README.zh-CN.md)

一个用于回退 [`sanwv/deploy-action`](https://github.com/sanwv/deploy-action) 部署版本的 GitHub Composite Action。它通过 SSH 将远端 `current` 符号链接切换到已有 release，不构建、不上传，也不删除 release。

## 工作原理

部署目录应采用以下结构：

```text
/srv/www/my-site/
├── current -> releases/<release-id>
├── releases/
│   ├── <release-id>/
│   └── ...
└── shared/
```

Action 获取与 `sanwv/deploy-action` 相同的远端锁（`<target>/.deploy.lock`），检查当前版本和回退目标，然后通过临时符号链接原子替换 `current`。切换后的钩子失败时，会在释放锁之前恢复原链接。回退不会删除任何 release。

`steps` 模式按 release 目录名的字典序排列版本。这与 `sanwv/deploy-action` 生成的 UTC 时间戳前缀（`YYYYMMDDTHHMMSSZ-<run-id>-<attempt>`）一致，不依赖目录修改时间。需要精确指定版本时使用 `release_id`。

## 配合 `sanwv/deploy-action` 使用

[`sanwv/deploy-action`](https://github.com/sanwv/deploy-action) 创建本 Action 可回退到的 release 目录。两个 Action 应配置相同的 SSH 主机、用户和 `target`。部署 Action 的 `releases_to_keep` 决定服务器保留多少历史版本；已被部署流程清理的版本无法通过回退恢复。

两个 Action 都会获取远端 `<target>/.deploy.lock`，以串行处理回退、版本激活和旧版本清理。部署与回退工作流还应使用相同的 GitHub Actions concurrency group，并设置 `cancel-in-progress: false`。部署参数、shared 文件、构建示例和保留策略见[部署 Action README](https://github.com/sanwv/deploy-action#readme)。

## 参数与输出

| 参数 | 必需 | 默认值 | 说明 |
|---|---:|---:|---|
| `ssh_private_key` | 是 | — | SSH 私钥，通过 GitHub Secret 传入。 |
| `remote_host` | 是 | — | 部署服务器主机名或 IP。 |
| `remote_user` | 是 | — | SSH 登录用户。 |
| `target` | 是 | — | 远端部署根目录，不是 `current` 目录。 |
| `ssh_known_hosts` | 否 | 空 | 已核验的 `known_hosts` 内容；留空时 SSH 使用 `accept-new`。 |
| `remote_port` | 否 | `22` | SSH 端口。 |
| `release_id` | 否 | 空 | 要激活的精确 release；与 `steps` 互斥。 |
| `steps` | 否 | 未指定 `release_id` 时为 `1` | 从当前版本向旧版本移动的步数，范围 `1`–`100`。 |
| `script_before` | 否 | 空 | 切换前在目标 release 目录中运行的远端 Bash 脚本。 |
| `script_after` | 否 | 空 | 切换后运行的远端 Bash 脚本；失败时恢复原版本。 |

输出 `previous_release` 和 `release_id` 分别是回退前的版本和本次激活的版本。

钩子脚本可读取环境变量：`ROLLBACK_TARGET`、`ROLLBACK_CURRENT_RELEASE`、`ROLLBACK_RELEASE_ID`、`ROLLBACK_RELEASE_PATH`、`ROLLBACK_HOOK`（值为 `before` 或 `after`）。

## 配置

在仓库 Actions Secrets/Variables 中添加：

| 名称 | 类型 | 说明 |
|---|---|---|
| `SSH_PRIVATE_KEY` | Secret | 服务器授权的 SSH 私钥。 |
| `SSH_KNOWN_HOSTS` | 可选 Secret 或 Variable | 已核验的服务器 host key。 |
| `REMOTE_HOST` | Variable | 服务器主机名或 IP。 |
| `REMOTE_USER` | Variable | SSH 用户。 |
| `REMOTE_PORT` | 可选 Variable | SSH 端口，默认 `22`。 |

服务器需要 Bash、`flock`、`realpath`、`find`、`sort` 和常见 GNU/Linux 工具。SSH 用户需有权限读取 releases，并创建符号链接以及写入 `<target>/.deploy.lock` 和 `<target>/current`。

## 示例

### 回退一个版本

```yaml
name: Rollback production

on:
  workflow_dispatch:

# 部署工作流也使用同一个组；不要取消正在执行的部署。
concurrency:
  group: production-deploy
  cancel-in-progress: false

jobs:
  rollback:
    runs-on: ubuntu-latest
    environment: production
    steps:
      - uses: sanwv/rollback-action@v1
        id: rollback
        with:
          ssh_private_key: ${{ secrets.SSH_PRIVATE_KEY }}
          ssh_known_hosts: ${{ secrets.SSH_KNOWN_HOSTS }}
          remote_host: ${{ vars.REMOTE_HOST }}
          remote_user: ${{ vars.REMOTE_USER }}
          remote_port: ${{ vars.REMOTE_PORT }}
          target: /srv/www/my-site
          steps: 1
      - run: echo "已从 ${{ steps.rollback.outputs.previous_release }} 回退到 ${{ steps.rollback.outputs.release_id }}"
```

### 在 Actions 页面指定 release

```yaml
name: Roll back to selected release

on:
  workflow_dispatch:
    inputs:
      release_id:
        description: Exact release ID to activate
        required: true
        type: string

concurrency:
  group: production-deploy
  cancel-in-progress: false

jobs:
  rollback:
    runs-on: ubuntu-latest
    environment: production
    steps:
      - uses: sanwv/rollback-action@v1
        with:
          ssh_private_key: ${{ secrets.SSH_PRIVATE_KEY }}
          remote_host: ${{ vars.REMOTE_HOST }}
          remote_user: ${{ vars.REMOTE_USER }}
          target: /srv/www/my-site
          release_id: ${{ inputs.release_id }}
```

### 回退两个版本并检查健康状态

```yaml
- uses: sanwv/rollback-action@v1
  with:
    ssh_private_key: ${{ secrets.SSH_PRIVATE_KEY }}
    remote_host: ${{ vars.REMOTE_HOST }}
    remote_user: ${{ vars.REMOTE_USER }}
    target: /srv/www/my-site
    steps: 2
    script_after: |
      curl --fail --max-time 10 http://127.0.0.1/health
```

切换后钩子失败时，Action 会恢复原符号链接并报告失败。回退只切换应用代码版本，不会还原数据库迁移、shared 文件、队列或其他外部状态。

## 连续回退和边界情况

假设保留的版本从旧到新为 A、B、C，当前为 C，执行 `steps: 1` 会切到 B；再次执行会切到 A。当前已是 A 时继续回退会以 `no older release available` 失败，且 `current` 保持不变。超过保留历史的步数也会失败。如果指定的 `release_id` 已经是当前版本，则成功结束，不做切换。

最大回退范围受部署 Action 的 `releases_to_keep` 限制。请按需要恢复的历史深度配置保留数量；已清理的 release 无法通过本 Action 恢复。

部署和回退工作流应使用相同的 GitHub Actions concurrency group；Action 还会使用共享的服务器端锁。详见 [GitHub 部署并发控制](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/control-deployments)。
