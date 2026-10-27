# ssh-pwlogin

一键开启 SSH 密码登录的小脚本：自动识别系统，全自动修正配置，整个过程只有"输两遍新密码"一步需要你动手。

## 一键运行

```bash
curl -fsSL https://raw.githubusercontent.com/tobaye/ssh-pwlogin/main/enable-pwlogin.sh | sudo sh
```

也可以先下载再运行（还能指定账户）：

```bash
curl -fsSL https://raw.githubusercontent.com/tobaye/ssh-pwlogin/main/enable-pwlogin.sh -o enable-pwlogin.sh
sudo sh enable-pwlogin.sh        # 给你当前这个账户开
sudo sh enable-pwlogin.sh opc    # 给指定账户开
```

## 它做了什么

1. **自动识别系统**：读 `/etc/os-release` 归类——Debian / Ubuntu 系、RHEL / Oracle Linux 系、Alpine、Arch，SSH 服务名（ssh / sshd）也自动选。
2. **把配置一次改对**：`/etc/ssh/sshd_config` 和 `sshd_config.d/*.conf` 里所有 `PasswordAuthentication` 一律改成 `yes`，再写一个 `01-` 开头的小文件钉死。原因是 sshd 对同一设置"先出现者生效"，小文件排在主文件前面——只改主文件会被小文件里的 `no` 压住（实测踩过这个坑，改多少遍 `sshd -T` 都是 no）。
3. **防回写**：cloud-init 里有 `ssh_pwauth` 开关就顺手改成 `true`，重启、关机再开都不会被首次启动策略打回去。
4. **先验证再重启**：用 `sshd -T` 确认生效值确实是 `yes` 才重启 SSH 服务；验证不通过就停下并打印所有出现位置，绝不拿你现有的连接冒险。
5. **唯一的交互**：给目标账户设密码（`passwd`，输两遍）。

密钥登录完全不碰，两者并存；重复运行安全（幂等）。

## 适用场景

甲骨文云（OCI）这类云厂商的镜像默认只许密钥登录：PuTTY 转密钥嫌麻烦、密钥文件丢了、或者想给服务器留一条密码登录的后路时，用它一次搞定。

⚠️ 公网开密码登录会被持续爆破扫描：密码务必设强一点，有条件再配个 fail2ban。
