# immichSlides 隐私政策 / Privacy Policy

最后更新 / Last Updated: 2026-10-01

## 中文

### 1. 适用范围和开发者身份

本隐私政策适用于 `immichSlides` iOS、iPadOS 和 tvOS 应用。

`immichSlides` 是一个连接用户自托管 Immich 服务器的照片轮播应用。它不是云相册服务，也不提供照片托管、备份、上传、删除或分享服务。

`immichSlides` 是独立开发的非官方应用。它不是 Immich 官方应用，也不隶属于 Immich 项目、Immich 团队或其相关权利方，未获得其官方背书、赞助或认可。`Immich` 名称仅用于说明本应用可以连接用户自己的 Immich 服务器。

本应用的开发者为：`sudoHG`。

开发者所在地为：`中国`。

联系方式为：`by331works@gmail.com`。

### 2. 角色与责任

为了避免误解，本政策先说明不同场景下的责任边界：

- 对于应用在用户设备本地保存和处理的数据，例如服务器地址、API Key、播放设置、筛选设置、访问保护设置、图片缓存和 Apple Vision 本地人脸数量检测，开发者通常不能访问这些数据。
- 对于用户配置的 Immich 服务器，数据处理由用户、家庭管理员、服务器管理员、第三方托管方或其他控制该服务器的人决定。开发者不托管用户的 Immich 服务器，也不控制该服务器上的照片库、账号、相册、人物标签或日志。
- 对于用户主动通过电子邮件、网站表单、GitHub Issues 或其他支持渠道发送给开发者的信息，开发者会作为该支持资料的处理者 / 控制者处理这些资料，用于回复用户和排查问题。

### 3. 我们处理哪些数据

当前版本的 `immichSlides` 不会通过应用本身把用户的照片、Immich API Key、Immich 服务器地址、播放记录、筛选条件或使用数据发送给 `immichSlides` 开发者。

应用会在用户设备本地处理必要数据，以完成连接 Immich、读取照片、播放照片、缓存图片、保存设置和访问保护等功能。

如果用户主动联系开发者寻求支持，开发者可能会收到用户主动提供的联系方式、问题描述、截图、日志片段或其他支持资料。

| 处理活动 | 数据类别 | 处理目的 | 欧盟 / 英国 GDPR 下可能适用的法律依据 |
|---|---|---|---|
| 保存服务器配置和播放偏好 | 服务器地址、API Key、播放设置、筛选设置、PIN 保护设置 | 提供用户请求的连接、轮播、筛选和访问保护功能 | 履行用户请求的服务；必要时基于用户同意 |
| 请求用户配置的 Immich 服务器 | 相册、人物、照片、缩略图、EXIF、地点元数据、资产列表 | 显示照片、生成播放池、展示筛选结果和 EXIF 信息 | 履行用户请求的服务 |
| 图片缓存和预加载 | 缩略图、预览图、播放图片、缓存状态 | 减少重复下载，改善播放体验 | 履行用户请求的服务；开发者的正当利益，即提升应用性能 |
| Apple Vision 本地人脸数量检测 | 照片图片、本地检测出的人脸数量 | 实现人物筛选中的 `soloOnly` 单人模式 | 履行用户请求的服务；如当地法律要求，则基于单独同意 |
| 支持请求 | 邮箱地址、问题描述、截图、日志、设备或系统版本 | 回复用户、排查故障、处理权利请求 | 用户同意；开发者的正当利益，即提供支持和维护应用 |

### 4. 应用在设备本地保存的数据

为了让应用正常工作，`immichSlides` 会在用户设备上保存以下数据：

- Immich 服务器地址：保存在设备本地，用于后续继续连接用户指定的 Immich 服务器。
- Immich API Key：保存在 Apple Keychain 中。Keychain 是 Apple 系统提供的安全凭据存储区。
- 播放设置：例如自动播放开关、播放间隔、默认播放模式、EXIF 显示开关等。
- 筛选设置：例如已选择的相册、人物和人物筛选模式。
- 访问保护设置：如果用户启用 PIN，应用会保存加盐哈希后的 PIN 数据，不保存明文 PIN。
- 图片缓存：应用可能缓存缩略图、预览图或播放用图片，以减少重复下载并改善播放体验。

这些数据主要保存在用户设备本地。开发者不会主动接收这些数据。

### 5. 与 Immich 服务器通信的数据

用户配置 Immich 服务器后，应用会直接向该服务器请求完成照片轮播所需的数据，包括：

- 相册列表、相册封面和照片数量；
- 人物列表、人物缩略图和人物照片数量；
- 照片缩略图、预览图和播放图片；
- 照片元数据，例如拍摄时间、相机型号、镜头信息、地点信息和其他可用 EXIF 信息；
- 随机播放或筛选播放所需的资产列表。

这些请求发生在用户设备和用户配置的 Immich 服务器之间。应用会把用户的 API Key 作为请求头发送给用户配置的 Immich 服务器，以完成认证和读取照片库。这是应用核心功能所必需的通信。

如果用户的 Immich 服务器由第三方托管，相关数据处理还会受到该服务器托管方或管理员的隐私政策、安全措施和日志策略影响。

### 6. 本地网络访问

如果用户的 Immich 服务器位于局域网内，应用可能需要访问本地网络，以连接和验证该服务器。

应用请求本地网络访问的目的仅是连接用户指定的 Immich 服务器。应用不会为了广告、用户画像或跨应用追踪目的扫描本地网络。

### 7. Apple Vision 本地人脸数量检测

当用户使用人物筛选中的单人模式（`soloOnly`）时，应用可能使用 Apple Vision 在设备本地检测照片中的人脸数量。

这项检测用于减少多人照片混入单人轮播。它只检测人脸数量，不识别人物身份，不创建人脸模板，不保存可用于身份识别的人脸特征，不出售或共享人脸数据，也不会把检测图片或检测结果主动发送给 `immichSlides` 开发者。

如果用户主动向开发者提交日志，日志片段可能包含照片资产 ID、人脸数量、检测耗时或图片尺寸等排障信息。提交日志前，用户应删除不必要的私人信息。

### 8. 敏感个人信息和儿童照片

用户的照片、EXIF 地点信息、人物信息、人脸数量检测结果，以及可能包含儿童的照片，在某些国家或地区可能被视为敏感个人信息。

`immichSlides` 处理这些数据的目的仅是提供用户请求的照片轮播、筛选、EXIF 展示、缓存和本地人脸数量检测功能。应用不会为了广告、数据经纪、用户画像、跨应用追踪或推断种族、宗教、政治观点、健康状况等目的处理照片内容。

请不要通过支持请求向开发者发送不必要的敏感信息、儿童照片、API Key、私人服务器地址、完整照片库截图或未遮挡的日志。

### 9. 第三方组件和第三方服务

当前版本使用以下第三方开源组件加载和缓存图片：

- `SDWebImage`
- `SDWebImageSwiftUI`

这些组件用于图片下载、显示和缓存。当前版本没有集成广告 SDK、第三方分析 SDK、第三方崩溃收集 SDK 或跨应用追踪 SDK。

如果用户通过第三方平台联系开发者，例如电子邮件服务、网站表单、GitHub Issues 或应用商店评论，用户提交的信息可能会由相应第三方平台处理，并受该平台自己的隐私政策约束。

### 10. 数据分享、出售、广告、分析和追踪

`immichSlides` 开发者不会出售、出租或共享用户的照片、API Key、服务器地址、播放记录或筛选条件。

当前版本没有广告，不使用第三方分析服务，不使用第三方崩溃收集服务，也不进行跨应用或跨网站追踪。

应用不会为了广告、数据经纪、用户画像或跨应用追踪目的收集或共享用户数据。

### 11. 数据保留和删除

本地数据通常会保留在用户设备上，直到用户执行以下操作：

- 在应用内修改服务器配置；
- 在应用内清理图片缓存；
- 修改或关闭访问保护；
- 删除应用；
- 在 Immich 服务器中撤销或删除对应 API Key；
- 在用户自己的 Immich 服务器中删除或修改相关照片、相册、人物标签或元数据。

如果用户担心 API Key 泄露，建议在 Immich 服务器后台撤销旧 API Key，并在应用中重新配置新的 API Key。

如果用户通过支持渠道向开发者提供了信息，开发者通常会在问题处理完成后最多保留 12 个月，除非法律义务、争议处理、安全排障或用户后续请求需要更长时间。用户可以通过本政策中的联系方式请求删除其支持资料。为防止误删或误操作，开发者可能需要用户提供足够信息来定位对应请求。

### 12. 用户选择和权利

用户可以通过以下方式控制自己的数据：

- 不再使用应用或删除应用；
- 在应用中修改服务器配置；
- 在应用中清理图片缓存；
- 在应用中关闭访问保护或修改 PIN；
- 在 Immich 服务器中撤销或删除 API Key；
- 在 Immich 服务器中管理、删除或修改自己的照片、相册、人物标签和元数据；
- 联系开发者，询问、访问、更正或请求删除用户主动提供给开发者的支持资料。

根据用户所在地区，用户可能拥有访问、更正、删除、限制处理、反对处理、撤回同意、数据可携带、要求解释说明、投诉监管机构等法定权利。由于当前版本的核心数据主要保存在用户设备和用户自己的 Immich 服务器中，许多数据请求需要用户在自己的设备或 Immich 服务器中完成。

### 13. 地区补充说明

#### 欧盟 / 英国 / 欧洲经济区

如果 GDPR 或英国数据保护法适用，用户可以联系开发者行使访问、更正、删除、限制处理、反对处理、数据可携带、撤回同意等权利。用户也可以向其所在地的数据保护监管机构投诉。

欧盟 / 英国代表：`Not applicable`。

数据保护官：`Not applicable`。

#### 日本

如果日本《个人信息保护法》适用，用户可以就开发者持有的支持请求资料联系开发者，请求披露、更正、追加、删除、停止利用或停止第三方提供。用户自己的 Immich 服务器数据应由用户或服务器管理员在 Immich 服务器中处理。

#### 中国大陆

如果《中华人民共和国个人信息保护法》或相关数据安全规则适用，用户可以联系开发者行使知情、决定、限制或拒绝处理、查阅、复制、更正、补充、删除、撤回同意、要求解释说明等权利。

本应用的核心照片数据主要在用户设备和用户自己的 Immich 服务器之间处理。开发者只会在用户主动提交支持请求时处理用户提供的资料。涉及敏感个人信息的功能，例如地点元数据展示和 `soloOnly` 本地人脸数量检测，仅用于用户请求的照片轮播和筛选功能。

如果支持渠道、邮件服务、网站托管或开发者所在地位于中国大陆以外，用户主动提交给开发者的支持资料可能会被传输至境外。用户不应在支持请求中提交不必要的敏感个人信息。

#### 美国

当前版本不出售个人信息，不共享个人信息用于跨情境行为广告，不使用广告 SDK，不使用第三方分析 SDK，也不创建、保存、出售或共享人脸模板、脸部几何记录或用于身份识别的生物识别数据。

`immichSlides` 不是面向 13 岁以下儿童的应用。如果开发者实际知道支持请求来自 13 岁以下儿童，开发者会删除相关支持资料，除非法律允许或要求保留。

如果 CCPA / CPRA 等州隐私法适用，用户可以联系开发者请求了解、访问、更正或删除开发者通过支持渠道持有的个人信息。由于开发者当前不出售或共享个人信息用于跨情境行为广告，通常不存在出售或共享的选择退出事项。

### 14. 跨境传输

应用的核心功能通常不需要把用户照片或 API Key 发送给开发者。照片和 API Key 的主要传输路径是用户设备与用户配置的 Immich 服务器之间。

如果用户主动通过电子邮件、网站、GitHub Issues、应用商店评论或其他支持渠道联系开发者，支持资料可能会根据开发者所在地、邮件服务商、网站服务商或第三方平台的位置发生跨境传输。

### 15. 安全

应用会把 Immich API Key 存入 Apple Keychain，并尽量减少敏感信息暴露。访问保护 PIN 会以加盐哈希后的形式保存，不保存明文 PIN。

如果用户的 Immich 服务器支持 HTTPS，建议优先使用 HTTPS 地址。使用 HTTP 或不安全的局域网连接时，网络传输安全性取决于用户自己的网络环境和服务器配置。

请妥善保管 Immich API Key。如果 API Key 泄露，拥有该 Key 的人可能访问用户的 Immich 照片库，具体权限取决于用户在 Immich 服务器中给该 API Key 配置的权限。

### 16. 儿童隐私

`immichSlides` 不是专门面向儿童的应用。应用不会故意向儿童收集个人信息。

用户的照片库可能包含儿童照片。开发者不会主动接收这些照片。用户不应通过支持渠道向开发者发送儿童照片，除非确有必要并且已经取得相关监护人授权。

### 17. 隐私政策变更

如果未来版本新增数据收集、分析、崩溃上报、云服务、账号系统、分享功能、反馈表单或其他会改变数据处理方式的功能，本隐私政策会相应更新。

重要变更会在应用内、隐私政策网页、App Store 页面或其他适当渠道提示。

### 18. 联系方式

如对本隐私政策或 `immichSlides` 的数据处理方式有疑问，或希望行使法定权利，请联系：

`by331works@gmail.com`

隐私政策网页：

`https://slides.by331.net/privacy/`

---

## English

### 1. Scope and Developer Identity

This Privacy Policy applies to the `immichSlides` app for iOS, iPadOS, and tvOS.

`immichSlides` is a photo slideshow app that connects to a self-hosted Immich server configured by the user. It is not a cloud photo service, and it does not provide photo hosting, backup, upload, deletion, or sharing services.

`immichSlides` is an independently developed unofficial app. It is not the official Immich app and is not affiliated with, endorsed by, sponsored by, or approved by the Immich project, the Immich team, or their related rights holders. The name `Immich` is used only to describe that this app can connect to a user’s own Immich server.

Developer: `sudoHG`

Developer location: `CHINA`

Contact: `by331works@gmail.com`

### 2. Roles and Responsibilities

To avoid confusion, this policy separates the main data handling scenarios:

- For data stored and processed locally on your device, such as the server address, API key, playback settings, filter settings, access protection settings, image cache, and on-device Apple Vision face count detection, the developer generally cannot access that data.
- For the Immich server you configure, data handling is controlled by you, your household administrator, your server administrator, your hosting provider, or whoever controls that server. The developer does not host your Immich server and does not control the photo library, accounts, albums, people labels, or logs on that server.
- For information you voluntarily send to the developer through email, website forms, GitHub Issues, or other support channels, the developer processes that support material to respond to you and troubleshoot issues.

### 3. Data We Process

The current version of `immichSlides` does not send your photos, Immich API key, Immich server address, playback history, filter selections, or usage data to the developer of `immichSlides` through the app itself.

The app processes necessary data locally on your device to connect to Immich, read photos, play slideshows, cache images, save settings, and provide access protection.

If you voluntarily contact the developer for support, the developer may receive contact details, issue descriptions, screenshots, log snippets, or other support material that you choose to provide.

| Processing activity | Data categories | Purpose | Possible legal basis under EU / UK GDPR |
|---|---|---|---|
| Saving server configuration and playback preferences | Server address, API key, playback settings, filter settings, PIN protection settings | Providing the connection, slideshow, filtering, and access protection features requested by the user | Performance of a user-requested service; consent where required |
| Requesting data from your configured Immich server | Albums, people, photos, thumbnails, EXIF, location metadata, asset lists | Showing photos, building slideshow pools, showing filters and EXIF information | Performance of a user-requested service |
| Image caching and preloading | Thumbnails, preview images, slideshow images, cache state | Reducing repeated downloads and improving playback performance | Performance of a user-requested service; legitimate interest in improving app performance |
| On-device Apple Vision face count detection | Photo image, locally detected face count | Providing the `soloOnly` people filter mode | Performance of a user-requested service; separate consent where required by local law |
| Support requests | Email address, issue description, screenshots, logs, device or system version | Responding to users, troubleshooting, and handling rights requests | Consent; legitimate interest in providing support and maintaining the app |

### 4. Data Stored Locally on Your Device

To provide its core functionality, `immichSlides` may store the following data on your device:

- Immich server address: stored locally so the app can continue connecting to the Immich server you configured.
- Immich API key: stored in Apple Keychain. Keychain is Apple’s secure credential storage system.
- Playback settings: such as autoplay, slideshow interval, default playback mode, and EXIF display settings.
- Filter settings: such as selected albums, selected people, and people filter modes.
- Access protection settings: if you enable a PIN, the app stores salted and hashed PIN data. It does not store the plain-text PIN.
- Image cache: the app may cache thumbnails, preview images, or slideshow images to reduce repeated downloads and improve playback performance.

This data is primarily stored locally on your device. The developer does not actively receive this data.

### 5. Data Communicated With Your Immich Server

After you configure an Immich server, the app directly requests data from that server to provide the slideshow experience, including:

- Album lists, album covers, and asset counts;
- People lists, people thumbnails, and people asset counts;
- Photo thumbnails, preview images, and slideshow images;
- Photo metadata, such as capture time, camera model, lens information, location information, and other available EXIF information;
- Asset lists needed for random playback or filtered playback.

These requests happen between your device and the Immich server you configured. The app sends your API key as a request header to that server in order to authenticate and read your photo library. This communication is necessary for the app’s core functionality.

If your Immich server is hosted by a third party, that hosting provider or server administrator may have separate privacy practices, security controls, and logging practices.

### 6. Local Network Access

If your Immich server is on your local network, the app may need local network access to connect to and validate that server.

The purpose of local network access is only to connect to the Immich server you specify. The app does not scan your local network for advertising, profiling, or cross-app tracking purposes.

### 7. On-Device Apple Vision Face Count Detection

When you use the `soloOnly` people filter mode, the app may use Apple Vision on your device to detect the number of faces in a photo.

This detection is used to reduce multi-person photos in single-person slideshows. It counts faces only. It does not identify who a person is, does not create face templates, does not store facial features for identification, does not sell or share face data, and does not actively send the image or the detection result to the developer of `immichSlides`.

If you voluntarily submit logs to the developer, log snippets may include photo asset IDs, face counts, detection duration, or image dimensions for troubleshooting. You should remove unnecessary private information before submitting logs.

### 8. Sensitive Personal Information and Children’s Photos

Your photos, EXIF location information, people information, face count detection results, and photos that may include children may be considered sensitive personal information in some countries or regions.

`immichSlides` processes this data only to provide the slideshow, filtering, EXIF display, caching, and on-device face count detection features requested by the user. The app does not process photo contents for advertising, data brokerage, user profiling, cross-app tracking, or to infer race, religion, political opinions, health status, or similar characteristics.

Please do not send unnecessary sensitive information, children’s photos, API keys, private server addresses, full photo library screenshots, or unredacted logs through support requests.

### 9. Third-Party Components and Third-Party Services

The current version uses the following open-source components for image loading and caching:

- `SDWebImage`
- `SDWebImageSwiftUI`

These components are used for image downloading, display, and caching. The current version does not integrate advertising SDKs, third-party analytics SDKs, third-party crash reporting SDKs, or cross-app tracking SDKs.

If you contact the developer through a third-party platform, such as an email service, website form, GitHub Issues, or app store review, the information you submit may be processed by that platform and may be subject to that platform’s own privacy policy.

### 10. Data Sharing, Sale, Advertising, Analytics, and Tracking

The developer of `immichSlides` does not sell, rent, or share your photos, API key, server address, playback history, or filter selections.

The current version does not contain advertising, does not use third-party analytics services, does not use third-party crash reporting services, and does not perform cross-app or cross-website tracking.

The app does not collect or share user data for advertising, data brokerage, user profiling, or cross-app tracking purposes.

### 11. Data Retention and Deletion

Local data generally remains on your device until you take actions such as:

- Changing the server configuration in the app;
- Clearing the image cache in the app;
- Changing or disabling access protection;
- Deleting the app;
- Revoking or deleting the API key on your Immich server;
- Deleting or modifying relevant photos, albums, people labels, or metadata on your own Immich server.

If you are concerned that your API key may have been exposed, you should revoke the old API key in your Immich server and configure a new API key in the app.

If you provided information to the developer through a support channel, the developer generally retains that material for up to 12 months after the issue is handled, unless legal obligations, dispute handling, security troubleshooting, or follow-up requests require a longer period. You may use the contact information in this policy to request deletion of that support material. To avoid deleting the wrong information, the developer may need enough information to locate the relevant request.

### 12. Your Choices and Rights

You can control your data by:

- Stopping use of the app or deleting the app;
- Changing the server configuration in the app;
- Clearing the image cache in the app;
- Disabling access protection or changing the PIN in the app;
- Revoking or deleting the API key on your Immich server;
- Managing, deleting, or modifying your photos, albums, people labels, and metadata on your Immich server;
- Contacting the developer to ask about, access, correct, or request deletion of support materials you voluntarily provided to the developer.

Depending on where you live, you may have legal rights to access, correct, delete, restrict processing, object to processing, withdraw consent, request data portability, request an explanation, or lodge a complaint with a supervisory authority. Because the current version primarily stores core data on your device and on your own Immich server, many data requests must be handled on your own device or Immich server.

### 13. Regional Notices

#### European Union, United Kingdom, and European Economic Area

If the GDPR or UK data protection law applies, you may contact the developer to exercise rights of access, correction, deletion, restriction, objection, data portability, and withdrawal of consent. You may also lodge a complaint with your local data protection supervisory authority.

EU / UK representative: `Not applicable`

Data Protection Officer: `Not applicable`

#### Japan

If Japan’s Act on the Protection of Personal Information applies, you may contact the developer regarding support request materials held by the developer and request disclosure, correction, addition, deletion, suspension of use, or suspension of third-party provision. Data on your own Immich server should be handled by you or your server administrator within your Immich server.

#### Mainland China

If the Personal Information Protection Law of the People’s Republic of China or related data security rules apply, you may contact the developer to exercise rights to know, decide, restrict or refuse processing, access, copy, correct, supplement, delete, withdraw consent, and request an explanation.

The app’s core photo data is mainly processed between your device and your own Immich server. The developer processes material you provide only when you voluntarily submit a support request. Features that may involve sensitive personal information, such as location metadata display and `soloOnly` on-device face count detection, are used only for the slideshow and filtering features requested by the user.

If the support channel, email service, website hosting, or developer location is outside Mainland China, support materials you voluntarily submit to the developer may be transferred outside Mainland China. You should not submit unnecessary sensitive personal information in support requests.

#### United States

The current version does not sell personal information, does not share personal information for cross-context behavioral advertising, does not use advertising SDKs, does not use third-party analytics SDKs, and does not create, store, sell, or share face templates, face geometry records, or biometric data used for identity recognition.

`immichSlides` is not directed to children under 13. If the developer has actual knowledge that a support request came from a child under 13, the developer will delete the related support material unless retention is permitted or required by law.

If CCPA / CPRA or similar state privacy laws apply, you may contact the developer to request information about, access to, correction of, or deletion of personal information held by the developer through support channels. Because the developer currently does not sell or share personal information for cross-context behavioral advertising, there is generally no sale or sharing opt-out for this app.

### 14. International Transfers

The app’s core functionality generally does not require sending your photos or API key to the developer. The main transfer path for photos and API keys is between your device and the Immich server you configured.

If you voluntarily contact the developer through email, a website, GitHub Issues, app store reviews, or another support channel, support material may be transferred internationally depending on the developer’s location, email provider, website provider, or third-party platform.

### 15. Security

The app stores your Immich API key in Apple Keychain and aims to minimize exposure of sensitive information. Access protection PIN data is stored as a salted hash. The app does not store the plain-text PIN.

If your Immich server supports HTTPS, you should use an HTTPS server address. If you use HTTP or an unsecured local network connection, transport security depends on your own network environment and server configuration.

Please protect your Immich API key. If the key is exposed, whoever has the key may be able to access your Immich photo library, depending on the permissions configured for that API key on your Immich server.

### 16. Children’s Privacy

`immichSlides` is not directed to children. The app does not knowingly collect personal information from children.

Your photo library may include children’s photos. The developer does not actively receive those photos. You should not send children’s photos to the developer through support channels unless it is necessary and you have obtained appropriate authorization from the relevant parent or guardian.

### 17. Changes to This Privacy Policy

If a future version adds data collection, analytics, crash reporting, cloud services, account systems, sharing features, feedback forms, or other functionality that changes data handling practices, this Privacy Policy will be updated accordingly.

Important changes may be notified in the app, on the privacy policy webpage, on the App Store page, or through another appropriate channel.

### 18. Contact

If you have questions about this Privacy Policy or how `immichSlides` handles data, or if you want to exercise legal rights, please contact:

`by331works@gmail.com`

Privacy Policy URL:

`https://slides.by331.net/privacy/`
