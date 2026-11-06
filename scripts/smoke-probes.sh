# shellcheck shell=bash
# BookStack：sso=oidc（AUTH_AUTO_INITIATE）；清单没有 mcp。

web_assert() { grep -qi 'bookstack'; }   # stdin：OIDC 走完后落到应用真实页面

# 走完浏览器式 OIDC：带主人会话打开应用首页 → AUTH_AUTO_INITIATE 重定向到 Hydra authorize
# （核心会话自动登录，302 携 code 回 /oidc/callback）→ BookStack 建会话落回首页。
# 自动登录靠隐藏表单的 JS 提交，curl 跟不了：取表单里的 _token 手动 POST /oidc/login，
# 走完 BookStack 的本地处理，再打开设置的用户列表（管理员页），断言里面有主人的账号。
identity_check() {
  local login_page token reply
  login_page="$(web_get /)" || { echo "GET / 失败（拿不到自动登录表单）"; return 1; }
  token="$(grep -o 'name="_token" value="[^"]*"' <<<"$login_page" | head -1 | sed -E 's/.*value="([^"]*)".*/\1/')"
  [[ -n "$token" ]] || { echo "首页没有 OIDC 自动登录表单（缺 _token）"; return 1; }
  reply="$(curl -sS --noproxy '*' -L -b "$SMOKE_JAR" -c "$SMOKE_JAR" \
    --data "_token=$token" "$SMOKE_WEB_URL/oidc/login")" ||
    { echo "POST /oidc/login 请求失败"; return 1; }
  grep -qF "$SMOKE_OWNER" <<<"$reply" || {
    echo "POST /oidc/login 后没有落到已登录页面，应用返回开头：$(head -c 200 <<<"$reply" | tr '\n' ' ')"
    return 1
  }
  local users_page
  users_page="$(web_get /settings/users)" || { echo "GET /settings/users 失败：$users_page"; return 1; }
  grep -qF "$SMOKE_OWNER" <<<"$users_page" || { echo "用户列表里没有主人 $SMOKE_OWNER"; return 1; }
}
