# 云吞插件：BookStack

[BookStack](https://www.bookstackapp.com)（MIT）是自托管的 Wiki：书、章节、页面，所见即所得编辑，全文搜索。
这个插件把它装进云吞：网页经核心网关打开，数据都在自己家里。

开发、检查和发布脚本见[插件开发指南](https://github.com/geraldpeng6/wonton-docs/blob/main/develop.md)，
清单字段和权限规则见[插件规范](https://github.com/geraldpeng6/wonton-docs/blob/main/plugin-spec.md)。

## 行为

- 三个服务：`bookstack`（应用）、`db`（MariaDB）和 `init`（一次性，初始化管理员）。应用文件挂
  `${WONTON_APP_DATA}/config`，数据库在命名卷 `db-data`。
- **登录用 BookStack 自己的账号，不走云吞登录。** 为什么不接云吞的 OIDC：BookStack 上游硬性要求
  https 的 OIDC 签发方（`app/Access/Oidc/OidcProviderSettings.php` 无条件校验），而云吞核心只签发
  http 的 OIDC——核心网关在隧道里不用 TLS（`wonton-core` 的 `config.rs` 把公开地址的 scheme 写死
  `http`）。等核心网关支持 https 后可以再接。
- 没有默认账密。首次启动时 `init` 一次性服务用 BookStack 自带的
  `php artisan bookstack:create-admin --initial` 把管理员建成**你的云吞邮箱** + 核心生成的**随机密码**
  （所以要装这个插件，得先在云吞里填好邮箱）。保留数据重装、升级都不动这个账号和密码。
- **账密在哪里看**：插件的详情页里有 `lan_webui` 开关，打开后显示登录邮箱、密码和局域网地址，可以复制。
  开关打开才会把 80 端口开到局域网上（默认关，不开也不影响经网关登录）。
- 界面默认简体中文（`APP_LANG=zh_CN`）。`PUID`/`PGID` 透传给镜像，宿主上的文件归用户的用户。
- 健康检查：BookStack 探自己的 `/status` 就绪端点（连不上数据库或缓存时 500），MariaDB 用自带的
  `healthcheck.sh --connect`。

## 配置

装上即用，没有要用户填的配置（云吞邮箱在 App 的资料里填好即可，没填邮箱装不了）。核心注入的变量只在
compose 里引用：`WONTON_APP_URL`（生成绝对链接）、`WONTON_OWNER_EMAIL`/`WONTON_OWNER_NAME`（管理员账号）、
`WONTON_SECRET_*`（管理员密码和应用密钥、数据库密码）、`TZ`/`PUID`/`PGID`。

## 镜像

- BookStack 项目自己不发官方镜像；上游[安装文档](https://www.bookstackapp.com/docs/admin-installation/)把社区
  Docker 打包列出来，首选 LinuxServer.io 的 `lscr.io/linuxserver/bookstack`。标签 `v26.09.2-ls295`
  （上游最新稳定版 v26.09.2 的 LinuxServer 构建），按清单列表摘要固定，amd64 + arm64。
- 数据库用官方 `mariadb:12.1.2` 镜像，同样按摘要固定；数据库的大版本升级会改数据文件格式，
  Dependabot 配置里忽略了 `mariadb` 的大版本更新，升级由人手工做。

## 图标来源与许可

`icon.png` 取自 BookStack 官方仓库的 `public/icon.png`（固定到提交 5f306a11e73a），原样放在白色底上，没有重绘、改色或裁切；
来源、版权、处理方式和商标说明见 [NOTICE](NOTICE)。该标志为 BookStack 项目及其权利人的商标，仅用于识别本插件所集成的
应用；本插件不代表 BookStack 官方，也不表示获得 BookStack 的合作、认可或背书。
