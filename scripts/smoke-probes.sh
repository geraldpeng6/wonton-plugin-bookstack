# shellcheck shell=bash
# BookStack：sso=none（用 BookStack 自己的账号登录，不走云吞登录）；清单没有 mcp。
# 管理员由 init 一次性服务在首次启动时建好：主人的邮箱 + 核心生成的随机密码（secrets.admin_password），
# 账密经 lan.client 显示在插件详情页。云吞身份没有可断言的入口，身份项按规范记 N/A；
# 数据项用管理员账密走应用自己的登录表单：data_write 登录并建一本带随机标记的书，
# data_check 用同一份账密重新登录再搜这本书——密码变了或数据丢了都会在这里失败。

export IDENTITY_NA=1
export SMOKE_NOTE="sso: none：登录用 BookStack 自己的账号（管理员账密在插件详情页），不走云吞登录"
export E2E_NOTE="$SMOKE_NOTE"

web_assert() { grep -qi 'bookstack'; }   # stdin：应用自己的登录页（未登录时网关后的第一屏）

# init 一次性容器的名字和它配置里的管理员账密。密码只注入给 init（应用本身不需要它），
# 容器退出后 Docker 的容器配置仍在，docker inspect 读得到；不 exec、不碰宿主上的凭据。
_bs_container() {
  local id="${SMOKE_PLUGIN_ID:-${PROBES_PLUGIN_ID:-${plugin_id:-}}}"
  printf 'wonton-%s--%s--init' "${SMOKE_INSTANCE:-}" "${id//./-}"
}

_bs_admin_credentials() {
  local container env
  container="$(_bs_container)"
  env="$(docker inspect "$container" --format '{{range .Config.Env}}{{println .}}{{end}}')" ||
    { echo "读不到一次性容器 $container 的配置（docker inspect 失败）"; return 1; }
  _BS_EMAIL="$(grep -oE '^WONTON_OWNER_EMAIL=.*' <<<"$env" | head -1 | cut -d= -f2-)"
  _BS_PASSWORD="$(grep -oE '^WONTON_SECRET_ADMIN_PASSWORD=.*' <<<"$env" | head -1 | cut -d= -f2-)"
  [[ -n "$_BS_EMAIL" && -n "$_BS_PASSWORD" ]] ||
    { echo "init 容器配置里没有管理员账密（WONTON_OWNER_EMAIL / WONTON_SECRET_ADMIN_PASSWORD）"; return 1; }
}

# 用管理员账密走应用自己的登录表单（POST /login）。jar 里已有有效会话时 /login 会跳走，
# 那就直接用现成会话；登录被拒（账密不对）时报错——数据项靠这一步验证“密码没变、旧密码还能登录”。
_bs_login() {
  local page token reply
  page="$(curl -sS --noproxy '*' -L -b "$SMOKE_JAR" -c "$SMOKE_JAR" "${SMOKE_WEB_URL%/}/login")" ||
    { echo "拿不到登录页"; return 1; }
  if grep -q 'id="login-form"' <<<"$page"; then
    token="$(grep -o 'name="_token" value="[^"]*"' <<<"$page" | head -1 | sed -E 's/.*value="([^"]*)".*/\1/')"
    [[ -n "$token" ]] || { echo "登录页没有表单 _token，看到了：$(head -c 200 <<<"$page" | tr '\n' ' ')"; return 1; }
    reply="$(curl -sS --noproxy '*' -L -b "$SMOKE_JAR" -c "$SMOKE_JAR" \
      --data-urlencode "_token=$token" --data-urlencode "email=$_BS_EMAIL" --data-urlencode "password=$_BS_PASSWORD" \
      "${SMOKE_WEB_URL%/}/login")" || { echo "POST /login 请求失败"; return 1; }
    if grep -q 'id="login-form"' <<<"$reply"; then
      echo "登录被拒（账密不对或已改），看到了：$(head -c 200 <<<"$reply" | tr '\n' ' ')"
      return 1
    fi
  fi
}

data_write() {
  [[ -n "${SMOKE_STATE:-}" ]] || { echo "SMOKE_STATE 没设置：套件没传状态文件"; return 1; }
  local marker page csrf loc slug book_page
  marker="BS-SMOKE-$(date +%s)-$RANDOM"
  _bs_admin_credentials || return 1
  _bs_login || return 1
  page="$(web_get /)" || { echo "登录后拿不到应用首页"; return 1; }
  csrf="$(grep -o 'name="token" content="[^"]*"' <<<"$page" | head -1 | sed -E 's/.*content="([^"]*)".*/\1/')"
  [[ -n "$csrf" ]] || {
    echo "应用首页没有 CSRF token（meta name=token），看到了：$(head -c 200 <<<"$page" | tr '\n' ' ')"
    return 1
  }
  loc="$(web_get /books/ -d "_token=$csrf" --data-urlencode "name=$marker" -o /dev/null -w '%{redirect_url}')" ||
    { echo "POST /books/ 失败（可能 419/500），redirect：$loc"; return 1; }
  slug="${loc#*/books/}"
  slug="${slug%%[?]*}"
  [[ -n "$slug" && "$slug" != "$loc" ]] || { echo "建书后没拿到书的地址，redirect：${loc:-（空）}"; return 1; }
  book_page="$(web_get "/books/$slug")" || {
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
  _bs_admin_credentials || return 1
  _bs_login || return 1
  page="$(web_get "/search?term=$marker")" || {
    echo "拿不到搜索页，看到了：$(head -c 200 <<<"$page" | tr '\n' ' ')"
    return 1
  }
  # 搜索结果会把命中词用 <mark> 高亮、标记文字可能被标签切开，断言只认原文渲染的书链接。
  if grep -qF "/books/$slug" <<<"$page"; then
    echo "按标记搜到书 $slug（标记 $marker），数据还在，管理员密码仍可登录"
    return 0
  fi
  echo "按标记没搜到书：标记 $marker，书 $slug；看到了：$(head -c 300 <<<"$page" | tr '\n' ' ')"
  return 1
}

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
