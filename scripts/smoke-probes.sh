# BookStack：sso=oidc（AUTH_AUTO_INITIATE）；清单没有 mcp。
SSO=oidc
MCP=0

web_assert() { grep -qi 'bookstack'; }   # stdin：OIDC 走完后落到应用真实页面

# 走完浏览器式 OIDC：带主人会话打开应用首页 → AUTH_AUTO_INITIATE 重定向到 Hydra authorize
# （核心会话自动登录，302 携 code 回 /oidc/callback）→ BookStack 建会话落回首页。
# 然后打开设置的用户列表（管理员页），断言里面有主人的账号。
identity_check() {
  local page users_page
  page="$(curl -sS --noproxy '*' -o /dev/null -L -b "$SMOKE_JAR" -c "$SMOKE_JAR" -H 'Accept: text/html' "$SMOKE_WEB_URL/")" ||
    { echo "OIDC 自动登录链失败"; return 1; }
  users_page="$(web_get /settings/users)" || { echo "GET /settings/users 失败：$users_page"; return 1; }
  grep -qF "$SMOKE_OWNER" <<<"$users_page" || { echo "用户列表里没有主人 $SMOKE_OWNER"; return 1; }
}
