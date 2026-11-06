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

# ---------- data_write / data_check ----------
# 用 BookStack 自己的网页接口写一条数据：走完 SSO 拿应用会话，取页面里的 CSRF token
# （meta name=token），POST /books/ 建一本名字带随机标记的书，核对新书页面里有标记，
# 再把“标记<TAB>书 slug”写进 $SMOKE_STATE。data_check 重新走一遍会话，按标记搜
# /search，结果里必须还有这本书；对不上时打印看到了什么。
# 登录链走不通时这两个函数和 identity_check 一样会失败，不会假装通过。

_bs_state_line() {  # 成功时把状态行打到 stdout，失败时把原因打到 stdout 并返回 1
  if [[ -z "${SMOKE_STATE:-}" ]]; then
    echo "SMOKE_STATE 没设置：套件没传状态文件"
    return 1
  fi
  if [[ ! -s "$SMOKE_STATE" ]]; then
    echo "状态文件 $SMOKE_STATE 不存在或为空：data_write 没跑过？"
    return 1
  fi
  head -n 1 "$SMOKE_STATE"
}

data_write() {
  [[ -n "${SMOKE_STATE:-}" ]] || { echo "SMOKE_STATE 没设置：套件没传状态文件"; return 1; }
  local marker page csrf loc slug book_page
  marker="BS-SMOKE-$(date +%s)-$RANDOM"
  page="$(dweb --sso /)" || { echo "走完 SSO 后拿不到应用首页"; return 1; }
  csrf="$(grep -o 'name="token" content="[^"]*"' <<<"$page" | head -1 | sed -E 's/.*content="([^"]*)".*/\1/')"
  [[ -n "$csrf" ]] || {
    echo "应用首页没有 CSRF token（meta name=token），看到了：$(head -c 200 <<<"$page" | tr '\n' ' ')"
    return 1
  }
  loc="$(dweb /books/ -d "_token=$csrf" --data-urlencode "name=$marker" -o /dev/null -w '%{redirect_url}')" ||
    { echo "POST /books/ 失败（可能 419/500），redirect：$loc"; return 1; }
  slug="${loc#*/books/}"
  slug="${slug%%[?]*}"
  [[ -n "$slug" && "$slug" != "$loc" ]] || { echo "建书后没拿到书的地址，redirect：${loc:-（空）}"; return 1; }
  book_page="$(dweb "/books/$slug")" || {
    echo "建的书 /books/$slug 打不开，看到了：$(head -c 200 <<<"$book_page" | tr '\n' ' ')"
    return 1
  }
  grep -qF "$marker" <<<"$book_page" || {
    echo "建的书页面里没有标记（可能跳回了别的页面），看到了：$(head -c 200 <<<"$book_page" | tr '\n' ' ')"
    return 1
  }
  printf '%s\t%s\n' "$marker" "$slug" >"$SMOKE_STATE" || { echo "写不进状态文件 $SMOKE_STATE"; return 1; }
  echo "已建书 $slug（标记 $marker）"
}

data_check() {
  local line marker slug page
  line="$(_bs_state_line)" || { echo "$line"; return 1; }
  marker="${line%%$'\t'*}"
  slug="${line##*$'\t'}"
  page="$(dweb --sso "/search?term=$marker")" || {
    echo "走完 SSO 后拿不到搜索页，看到了：$(head -c 200 <<<"$page" | tr '\n' ' ')"
    return 1
  }
  if grep -qF "$marker" <<<"$page" && grep -qF "$slug" <<<"$page"; then
    echo "按标记搜到书 $slug（标记 $marker），数据还在"
    return 0
  fi
  echo "按标记没搜到书：标记 $marker，书 $slug；看到了：$(head -c 300 <<<"$page" | tr '\n' ' ')"
  return 1
}
