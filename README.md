# Meridian

给 Claude Code、Codex 这类本地 Agent 一间带锁的工作室。Agent 只看见你选中的项目文件夹。API Key、GitHub 令牌和电脑上的其他文件留在外面。

沙箱是这个 Mac 应用里的一台轻量 Linux 虚拟机。虚拟机没有网卡。它要联系模型、GitHub 或别的网站时，请求先回到 Meridian。真正的钥匙在钥匙串里，由 Meridian 在发出去之前附上。

## 准备

需要 Apple 芯片的 Mac，macOS 15 或更新，以及 Xcode 命令行工具。

```bash
make test
make app
make image
make run
```

`make image` 会下载 Alpine、Node，并尽量装上 Claude Code 和 Codex。这一步只在准备沙箱系统时需要网络，做好的系统里不包含任何钥匙。

也可以先 `make run`，在窗口里点「准备沙箱系统」。

`make dmg` 会生成 `dist/Meridian.dmg`。这是本机 Release 构建，用临时签名；别人安装时系统可能提醒未公证。

## 使用

1. 在 Meridian 里连接 Anthropic、OpenAI 或 GitHub。这一步只发生在这台电脑上。
2. 选择一个项目文件夹。`.env`、私钥、`.ssh` 这类文件默认不会送进沙箱。
3. 打开沙箱，运行 Claude Code、Codex 或终端。

沙箱里看到的模型钥匙是无效占位符 `meridian-local`。复制出去不能用。

GitHub 打开后，仓库访问由这台电脑代发。令牌不会进沙箱。第一次用到别的网站时，Meridian 会问你是否允许。内部网络地址一律拒绝。模型厂商的域名也不能从沙箱直接连，避免绕过代发。

## 边界

沙箱保护的是项目以外的这台电脑，以及所有钥匙。你放进项目里的代码，Agent 本来就要看。项目里原有的 `.env` 会留在外面，并在窗口里写明。
