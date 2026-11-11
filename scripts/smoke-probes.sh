# shellcheck shell=bash
# BookStack：sso=none（用 BookStack 自己的账号登录，不走云吞登录）。
# 管理员由 init 一次性服务在首次启动时建好：主人的邮箱 + 核心生成的随机密码（secrets.admin_password），
# 密码经 show_owner 在插件详情页显示。
# 身份：identity_check 从详情页用的密钥接口取密码，用户邮箱取主人资料；用它走应用登录表单，断言进入管理面板
#       且当前用户就是主人的邮箱。装的是新版本时接口必须给得出这一项（清单没写 show_owner、接口坏了都失败）；
#       升级的起点是没有这一项的旧版本，那时从 init 容器配置读。
# 数据：data_write 登录后建一本带随机标记的书；data_check 用同一份账密重新登录再搜这本书——
#       密码变了或数据丢了都会在这里失败。

web_assert() { grep -qi 'bookstack'; }   # stdin：应用自己的登录页（未登录时网关后的第一屏）

_bs_plugin_id() { printf '%s' "${SMOKE_PLUGIN_ID:-${PROBES_PLUGIN_ID:-${plugin_id:-}}}"; }

# 带主人令牌调核心：<方法> <路径> [curl 参数…]。仓库的探针套件（scripts/probes.sh）有 smoke_api，e2e 冒烟直接
# source 这份文件、没有它，按同一口径补一个。
_bs_api() {
  local method="$1" path="$2"
  shift 2
  if declare -F smoke_api >/dev/null; then
    smoke_api "$method" "$path" "$@"
  else
    curl -sS --noproxy '*' --fail-with-body -X "$method" -H "Authorization: Bearer $SMOKE_TOKEN" "$@" "$SMOKE_BASE$path"
  fi
}

_bs_container() { # init 一次性容器的名字；升级起点那一轮 SMOKE_INSTANCE 还没导出，实例名从 SMOKE_BASE 的主机名取
  local instance="${SMOKE_INSTANCE:-}"
  [[ -n "$instance" ]] || instance="${SMOKE_BASE#*://}"
  instance="${instance%%.*}"
  local id
  id="$(_bs_plugin_id)"
  printf 'wonton-%s--%s--init' "$instance" "${id//./-}"
}

_bs_marker_file() { # 标记文件：SMOKE_STATE 在 dev.sh probes 里是目录，目录里放标记文件
  if [[ -d "${SMOKE_STATE:-}" ]]; then printf '%s/data-marker' "$SMOKE_STATE"; else printf '%s' "${SMOKE_STATE:-}"; fi
}

# 旧版本（还没有 show_owner 的升级起点）的账密：密码只注入给 init（应用本身不需要它），容器退出后 Docker 的容器
# 配置仍在，docker inspect 读得到；不 exec、不碰宿主上的凭据。
_bs_container_credentials() {
  local env
  env="$(docker inspect "$(_bs_container)" --format '{{range .Config.Env}}{{println .}}{{end}}')" ||
    { echo "读不到一次性容器 $(_bs_container) 的配置（docker inspect 失败）"; return 1; }
  _BS_EMAIL="$(grep -oE '^WONTON_OWNER_EMAIL=.*' <<<"$env" | head -1 | cut -d= -f2-)"
  _BS_PASSWORD="$(grep -oE '^WONTON_SECRET_ADMIN_PASSWORD=.*' <<<"$env" | head -1 | cut -d= -f2-)"
  [[ -n "$_BS_EMAIL" && -n "$_BS_PASSWORD" ]] ||
    { echo "init 容器配置里没有管理员账密（WONTON_OWNER_EMAIL / WONTON_SECRET_ADMIN_PASSWORD）"; return 1; }
}

# 管理员账密：走详情页用的接口读，顺便断言清单把它声明成了主人可见（GET …/secrets 的列表里有 admin_password），
# 再取它的值登录；登录邮箱取主人资料。升级的起点是还没有 show_owner 的旧版本，接口给不出这一项，那时从 init
# 容器的配置里读，并说明走的是旧路（升级后的身份、数据两项仍会走接口）。
# 核心把信投进主人的私聊后马上从内部邮箱删掉（投完才删），等“信出现在 Mailpit”有竞态：
# 直接断言投递的结果——以主人身份读主人的 Wonton 私聊（通知房间），找这个插件发的信。

_mx_curl() { # <路径> [curl 参数…]：在核心容器的网络栈里调 Tuwunel 的 Matrix 客户端接口（宿主够不着）
  local path="$1"; shift
  docker run --rm --network "container:wonton-${SMOKE_INSTANCE:?}--core" curlimages/curl:8.23.0 \
    -sS --noproxy '*' --max-time 30 --fail-with-body "$@" "http://tuwunel.wonton.internal:8008$path"
}

_mx_room_mail() { # <插件 id>：以主人身份读主人的 Wonton 私聊，输出这个插件发进来的信（结构化事件数组）
  local core="wonton-${SMOKE_INSTANCE:?}--core" admin server room owner tok enc
  admin="$(docker exec "$core" sh -c 'cat "$WONTON_DATA_DIR/core/matrix-admin-token"')" ||
    { echo "拿不到核心的 Matrix 管理令牌"; return 1; }
  server="$(docker exec "$core" sh -c 'cat "$WONTON_MATRIX_SERVER_NAME_FILE" 2>/dev/null || printf %s "${WONTON_MATRIX_SERVER_NAME:-}"')"
  [[ -n "$server" ]] || { server="${SMOKE_BASE#*://}"; server="${server%%:*}"; }
  room="$(docker exec "$core" sh -c 'cat "$WONTON_DATA_DIR/core/matrix-notice-room" 2>/dev/null')" ||
    { echo "主人的通知房间还没建（还没投过信？）"; return 1; }
  enc="$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$room")"
  owner="@${SMOKE_OWNER:-owner}:$server"
  tok="$(_mx_curl "/_synapse/admin/v1/users/$owner/login" \
    -H "Authorization: Bearer $admin" -H 'Content-Type: application/json' -d '{}' | jq -er '.access_token // empty')" ||
    { echo "换不出主人的 Matrix 会话（impersonate 失败）"; return 1; }
  _mx_curl "/_matrix/client/v3/rooms/$enc/messages?dir=b&limit=30" -H "Authorization: Bearer $tok" |
    jq -c --arg id "$1" '[.chunk[] | select(.content["app.wonton.plugin_mail"].plugin_id == $id)]'
}

_mx_wait_mail() { # <插件 id> [轮数=30]：轮询主人的私聊，等这封信出现在房间里（每轮 2 秒）
  local id="$1" n="${2:-30}" i chunk
  for ((i = 0; i < n; i++)); do
    chunk="$(_mx_room_mail "$id")" || { sleep 2; continue; }
    [[ "$chunk" != "[]" ]] && { printf '%s' "$chunk"; return 0; }
    sleep 2
  done
  return 1
}

_bs_admin_credentials() {
  local list me
  list="$(_bs_api GET "/_wonton/api/plugins/$(_bs_plugin_id)/secrets")" ||
    { echo "读不到主人可见的密钥列表（GET …/secrets 失败）"; return 1; }
  _BS_LABEL="$(jq -r '.secrets[] | select(.name == "admin_password") | .label' <<<"$list")"
  if [[ -n "$_BS_LABEL" ]]; then
    me="$(_bs_api GET /_wonton/api/me)" || { echo "读不到主人资料（GET /me 失败）"; return 1; }
    _BS_EMAIL="$(jq -r '.email // empty' <<<"$me")"
    _BS_PASSWORD="$(_bs_api GET "/_wonton/api/plugins/$(_bs_plugin_id)/secrets/admin_password" | jq -r '.value')" ||
      { echo "取不到 admin_password 的值（GET …/secrets/admin_password 失败）"; return 1; }
  else
    echo "密钥列表里没有 admin_password（旧版本没有 show_owner？），从 init 容器配置读"
    _bs_container_credentials || return 1
  fi
  [[ -n "$_BS_EMAIL" && -n "$_BS_PASSWORD" ]] ||
    { echo "主人资料里没有邮箱（App 里没填？）或管理员密码为空"; return 1; }
}

# 建立核心会话，写进 SMOKE_JAR。两套冒烟的 dweb 对 jar 的处理不一样（e2e 的不带 --jar，
# 会话落在检出目录的 .wonton 里），这里自己做，不依赖 dweb。
_bs_session() {
  rm -f "$SMOKE_JAR"
  curl -sS --noproxy '*' --fail-with-body -o /dev/null -c "$SMOKE_JAR" \
    --data-urlencode "token=$SMOKE_TOKEN" "$SMOKE_BASE/_wonton/login" ||
    { echo "用户令牌登录不了核心"; return 1; }
  curl -sS --noproxy '*' -o /dev/null -L -b "$SMOKE_JAR" -c "$SMOKE_JAR" -H 'Accept: text/html' \
    "${SMOKE_WEB_URL%/}/" || { echo "走不通插件网页的登录跳转"; return 1; }
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
  local marker page csrf loc slug book_page
  marker="BS-SMOKE-$(date +%s)-$RANDOM"
  _bs_session || return 1
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
  printf '%s\t%s\n' "$marker" "$slug" >"$(_bs_marker_file)" || { echo "写不进状态文件 $(_bs_marker_file)"; return 1; }
  echo "已建书 $slug（标记 $marker）"
}

data_check() {
  local line marker slug page
  line="$(_bs_state_line)" || { echo "$line"; return 1; }
  marker="${line%%$'\t'*}"
  slug="${line##*$'\t'}"
  _bs_session || return 1
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
  local mf
  mf="$(_bs_marker_file)"
  if [[ ! -s "$mf" ]]; then
    echo "状态文件 $mf 不存在或为空：data_write 没跑过？（SMOKE_STATE=${SMOKE_STATE:-未设置}）"
    return 1
  fi
  head -n 1 "$mf"
}

identity_check() { # 应用自己的登录链：详情页接口取到的管理员密码登录后进管理面板，当前用户是主人邮箱
  SMOKE_WEB_URL="${SMOKE_WEB_URL%/}"  # 套件给的地址带尾斜杠，拼路径前剥掉，避免 // 打不进路由
  local page
  _bs_admin_credentials || return 1
  _bs_login || return 1
  page="$(web_get /settings/users)" || { echo "管理面板 /settings/users 打不开（非管理员？）：$page"; return 1; }
  grep -qF "$_BS_EMAIL" <<<"$page" || { echo "管理面板里没有主人邮箱 $_BS_EMAIL：$(head -c 200 <<<"$page" | tr '\n' ' ')"; return 1; }
  page="$(web_get /my-account/profile)" || { echo "/my-account/profile 打不开：$page"; return 1; }
  grep -qF "$_BS_EMAIL" <<<"$page" || { echo "当前用户不是主人（$_BS_EMAIL）：$(head -c 200 <<<"$page" | tr '\n' ' ')"; return 1; }
  local src="init 容器配置（旧版本）"
  [[ -n "$_BS_LABEL" ]] && src="详情页接口「$_BS_LABEL」"
  echo "登录通过（密码来源：$src）：应用认出主人 $_BS_EMAIL，且能进管理面板"
}

# ---------- 内部邮箱（notify）的端到端检查 ----------

_mp_api() { # <路径>：调 Mailpit 的 HTTP API（basic core:<api-password>）。Mailpit 只挂在插件网络，
  # 宿主够不着；照核心自己 smoke-mailbox 的做法，在核心容器的网络栈里起一次性 curl 访问它。
  local core pw dd out
  core="wonton-${SMOKE_INSTANCE:?}--core"
  docker inspect "$core" >/dev/null 2>&1 || { echo "找不到核心容器 $core"; return 1; }
  if declare -F read_env >/dev/null; then dd="$(read_env WONTON_DATA_DIR)"
  elif declare -F probes_setting >/dev/null; then dd="$(probes_setting WONTON_DATA_DIR)"
  else echo "读不到 WONTON_DATA_DIR（read_env / probes_setting 都没有）"; return 1; fi
  pw="$(docker exec "$core" cat "$dd/core/mailpit/api-password" 2>/dev/null)"
  [[ -n "$pw" ]] || { echo "读不到 Mailpit API 密码（核心数据目录 core/mailpit/api-password）"; return 1; }
  out="$(docker run --rm --network "container:$core" curlimages/curl:8.23.0 \
    -s -u "core:$pw" "http://mailpit.wonton.internal:8025$1" 2>&1)"
  if [[ "$out" == "{"* ]]; then printf '%s' "$out"; return 0; fi
  echo "Mailpit 没给出 JSON：$(head -c 200 <<<"$out")"
  return 1
}

_mp_wait() { # <jq 参数…> [轮数=20]：轮询 Mailpit 信箱直到过滤命中。参数原样交给 jq（--arg 键 值、过滤串）；
  # 最后一个参数是纯数字时取作轮数。
  local -a args=()
  local n=20 a i out
  while (($#)); do
    a="$1"; shift
    if (($# == 0)) && [[ "$a" =~ ^[0-9]+$ ]]; then n="$a"; else args+=("$a"); fi
  done
  ((${#args[@]})) || { echo "mp_wait 没给 jq 过滤"; return 1; }
  for ((i = 0; i < n; i++)); do
    out="$(_mp_api "/api/v1/messages?limit=100")" || { sleep 3; continue; }
    jq -e "${args[@]}" <<<"$out" >/dev/null 2>&1 && return 0
    sleep 3
  done
  return 1
}

extra_check() { # 内部邮箱端到端：发信环境变量注入、真实找回密码信进 Mailpit、核心投进主人私聊后删掉
  local appc mail_host mail_port
  appc="$(docker ps --format '{{.Names}}' | grep -E -- "-bookstack--bookstack$|bookstack-bookstack-1$" | head -1)"
  [[ -n "$appc" ]] || { echo "找不到 bookstack 应用容器"; return 1; }
  mail_host="$(docker exec "$appc" printenv MAIL_HOST)" || { echo "应用容器没有 MAIL_HOST"; return 1; }
  mail_port="$(docker exec "$appc" printenv MAIL_PORT)" || { echo "应用容器没有 MAIL_PORT"; return 1; }
  [[ "$mail_host" == "smtp.wonton.internal" && "$mail_port" == "25" ]] ||
    { echo "发信环境变量不对：MAIL_HOST=$mail_host MAIL_PORT=$mail_port"; return 1; }
  echo "发信环境变量已注入：$mail_host:$mail_port"

  # 收件人是管理员账号的邮箱（重装对齐后就是主人的内部邮箱）；先建立会话和账密
  _bs_session || return 1
  _bs_admin_credentials || return 1
  _bs_login || return 1
  local to
  to="$_BS_EMAIL"
  [[ -n "$to" ]] || { echo "主人资料里没有邮箱"; return 1; }

  # 真实找回密码信：POST /forgot-password（页面的 _token 是 CSRF）
  local page token
  page="$(web_get /forgot-password)" || { echo "拿不到找回密码页：$(head -c 200 <<<"$page")"; return 1; }
  token="$(grep -o 'name="_token" value="[^"]*"' <<<"$page" | head -1 | sed -E 's/.*value="([^"]*)".*/\1/')"
  [[ -n "$token" ]] || { echo "找回密码页没有 _token"; return 1; }
  web_get /forgot-password -d "_token=$token" --data-urlencode "email=$to" -o /dev/null ||
    { echo "POST /forgot-password 失败"; return 1; }
  # shellcheck disable=SC2016  # jq 程序，不能让 bash 展开
  _mx_wait_mail app.bookstack.bookstack ||
    { echo "60 秒内没在主人的 Wonton 私聊看到 BookStack 的找回密码信（收件人 $to）"; return 1; }
  echo "找回密码信已投进 $to 的 Wonton 私聊"
}
