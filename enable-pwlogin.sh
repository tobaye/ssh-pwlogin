#!/bin/sh
###############################################################################
# enable-pwlogin.sh — 一键开启 SSH 密码登录
#
# 针对实测踩过的坑设计（甲骨文 Oracle Linux / Debian / Ubuntu 等云镜像）：
# 坑 1：只改 /etc/ssh/sshd_config 没用。sshd 对同一设置"先出现者生效"，
# 而 sshd_config.d/ 里的小文件排在主文件正文前面，它写 no 就把
# 主文件压住，改主文件一百遍 sshd -T 还是 no。
# → 本脚本把主文件和所有小文件里的 PasswordAuthentication 全部
# 改成 yes，再放一个排在最前的小文件钉死，双保险。
# 坑 2：不同系统命令不同（服务名 ssh / sshd、cloud-init 开关……）。
# → 本脚本读 /etc/os-release 自动归类，一套脚本通用。
# 坑 3：没设密码、或没验证生效值就重启 sshd，容易把自己锁在门外。
# → 本脚本先用 sshd -T 验证生效值确为 yes 才重启；不通过就停下
# 并打印所有出现位置，绝不拿你现有的连接冒险。
#
# 唯一的交互：给账户设密码时输两遍（passwd 的系统提示，绕不开）。
# 密钥登录不碰，两者并存。重复运行安全（幂等）。
#
# 用法：
#   curl -fsSL https://raw.githubusercontent.com/tobaye/ssh-pwlogin/main/enable-pwlogin.sh | sudo sh
#   或先下载到本地再运行：sudo sh enable-pwlogin.sh [用户名]
# 不带用户名时，给"调用 sudo 的那个账户"设（也就是你本人）。
###############################################################################

set -u

# 路径可用环境变量覆盖（主要供自动化测试；正常使用不用管）
SSHD_MAIN=${SSHD_MAIN:-/etc/ssh/sshd_config}
SSHD_DIR=${SSHD_DIR:-/etc/ssh/sshd_config.d}
CLOUD_CFG=${CLOUD_CFG:-/etc/cloud/cloud.cfg}
CLOUD_CFG_DIR=${CLOUD_CFG_DIR:-/etc/cloud/cloud.cfg.d}
OS_RELEASE=${OS_RELEASE:-/etc/os-release}
DROPIN_NAME=01-enable-password-login.conf

info() { printf '[信息] %s\n' "$*";}
warn() { printf '[警告] %s\n' "$*";}
die() { printf '[错误] %s\n' "$*" >&2; exit 1;}

# ---------- 目标账户与提权 ----------
TARGET_USER=${1:-${SUDO_USER:-}}
[ -n "$TARGET_USER" ] || TARGET_USER=$(id -un)

if [ "$(id -u)" -ne 0 ]; then
command -v sudo >/dev/null 2>&1 || die "需要 root 权限，这台机器又没有 sudo，请改用 root 运行"
info "需要 root 权限，正在用 sudo 重新运行……"
  [ -f "$0" ] || die "当前是管道方式运行且不是 root，没法自动提权。请先下载再运行：curl -fsSL https://raw.githubusercontent.com/tobaye/ssh-pwlogin/main/enable-pwlogin.sh -o enable-pwlogin.sh，然后 sudo sh enable-pwlogin.sh"
exec sudo /bin/sh "$0" "$TARGET_USER"
fi
id "$TARGET_USER" >/dev/null 2>&1 || die "账户 $TARGET_USER 不存在"

# ---------- 识别系统 ----------
OS_ID=; OS_LIKE=; PRETTY=
if [ -r "$OS_RELEASE" ]; then
# shellcheck disable=SC1090
. "$OS_RELEASE"
OS_ID=${ID:-}; OS_LIKE=${ID_LIKE:-}; PRETTY=${PRETTY_NAME:-}
fi
FAMILY=unknown
case " $OS_ID $OS_LIKE " in
*' debian '*|*' ubuntu '*) FAMILY=debian;;
*' ol '*|*' rhel '*|*' centos '*|*' fedora '*|*' rocky '*|*' almalinux '*|*' amzn '*) FAMILY=rhel;;
*' alpine '*) FAMILY=alpine;;
*' arch '*) FAMILY=arch;;
esac
info "系统：${PRETTY:-未知}（归类：$FAMILY）"
info "目标账户：$TARGET_USER"

# ---------- 修 sshd 配置：全部改 yes + 钉死小文件 ----------
[ -f "$SSHD_MAIN" ] || die "找不到 $SSHD_MAIN —— 这台机器可能没装 SSH 服务端"
mkdir -p "$SSHD_DIR"

PA_RE='^[[:space:]]*#?[[:space:]]*PasswordAuthentication[[:space:]]'
for f in "$SSHD_MAIN" "$SSHD_DIR"/*.conf; do
[ -f "$f" ] || continue
if grep -qiE "$PA_RE" "$f"; then
sed -i -E "s|$PA_RE.*|PasswordAuthentication yes|" "$f"
info "已把 $f 里的 PasswordAuthentication 改为 yes"
fi
done

printf 'PasswordAuthentication yes\n' > "$SSHD_DIR/$DROPIN_NAME"
info "已写入钉死小文件：$SSHD_DIR/$DROPIN_NAME"

# 主文件既不读小文件目录、自己又没有这一项时，直接补进主文件
if ! grep -qE '^[[:space:]]*Include[[:space:]].*sshd_config\.d' "$SSHD_MAIN" && ! grep -qiE "$PA_RE" "$SSHD_MAIN"; then
echo 'PasswordAuthentication yes' >> "$SSHD_MAIN"
info "主配置不读小文件目录，已直接补进 $SSHD_MAIN"
fi

# ---------- cloud-init 的 ssh_pwauth（防它按首次启动策略回写） ----------
for f in "$CLOUD_CFG" "$CLOUD_CFG_DIR"/*.cfg; do
[ -f "$f" ] || continue
if grep -qE '^[[:space:]]*ssh_pwauth:' "$f"; then
sed -i -E 's|^([[:space:]]*)ssh_pwauth:.*|\1ssh_pwauth: true|' "$f"
info "cloud-init ssh_pwauth 已改为 true：$f"
fi
done

# ---------- 验证生效值（不通过绝不重启） ----------
SSHD_BIN=$(command -v sshd || true)
[ -n "$SSHD_BIN" ] || SSHD_BIN=/usr/sbin/sshd
EFF=$("$SSHD_BIN" -T 2>/dev/null | awk 'tolower($1) == "passwordauthentication" { print tolower($2)}')
if [ "$EFF" != "yes" ]; then
warn "sshd 当前生效值不是 yes（得到：${EFF:-读取失败}），所有出现位置如下："
grep -rniE 'passwordauthentication' "$SSHD_MAIN" "$SSHD_DIR" 2>/dev/null || true
die "已停下：没有重启 sshd，你现在的连接不受影响。把上面的输出留好排查。"
fi
info "验证通过：sshd -T 显示 passwordauthentication yes"

# ---------- 唯一的交互：设密码 ----------
if [ "${PWLOGIN_SKIP_PASSWD:-0}" != "1" ]; then
info "接下来给 $TARGET_USER 设登录密码（要输两遍，屏幕不显示字符是正常的）"
  # 管道方式运行时 stdin 是脚本本身，密码必须从终端 /dev/tty 读
  PW_FAIL="密码没设成功。配置已就绪：重跑本脚本，或手动 passwd $TARGET_USER 设好密码再重启 sshd 即可"
  if [ -r /dev/tty ]; then
    passwd "$TARGET_USER" < /dev/tty || die "$PW_FAIL"
  else
    passwd "$TARGET_USER" || die "$PW_FAIL"
  fi
fi

# ---------- 按系统重启 SSH 服务 ----------
detect_service() {
if command -v systemctl >/dev/null 2>&1; then
if systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}' | grep -qx 'ssh.service'; then
echo ssh; return
fi
if systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}' | grep -qx 'sshd.service'; then
echo sshd; return
fi
fi
case "$FAMILY" in
debian) echo ssh;;
*) echo sshd;;
esac
}
SVC=$(detect_service)
if [ "${PWLOGIN_NO_RESTART:-0}" = "1" ]; then
info "（测试模式）跳过重启，识别到的服务名：$SVC"
else
if command -v systemctl >/dev/null 2>&1; then
systemctl restart "$SVC" || die "重启 $SVC 失败，当前连接不受影响，请用 systemctl status $SVC 查看"
elif command -v rc-service >/dev/null 2>&1; then
rc-service "$SVC" restart || die "重启 $SVC 失败，当前连接不受影响"
elif command -v service >/dev/null 2>&1; then
service "$SVC" restart || die "重启 $SVC 失败，当前连接不受影响"
else
die "不知道这台机器用什么管服务，请手动重启 SSH 服务（服务名大概是 $SVC）"
fi
info "SSH 服务已重启（服务名：$SVC）"
fi

cat <<EOF

[完成] SSH 密码登录已开启
账户：$TARGET_USER
密钥登录：未改动，两者并存
下一步：新开一个连接，用 $TARGET_USER + 刚设的密码试登，成功后再关旧窗口
EOF
