<p align="center">
  <img src="assets/logo.png" width="128" alt="Notchikko">
</p>

<h1 align="center">Notchikko</h1>

<p align="center"><em>섬의 생물: 고개를 들면, 그곳에 다정함이.</em></p>

<p align="center">
  <a href="README.md">English</a> ·
  <a href="README.zh-CN.md">简体中文</a> ·
  <a href="README.zh-TW.md">繁體中文</a> ·
  <a href="README.ja.md">日本語</a> ·
  <strong>한국어</strong>
</p>

화면 위쪽의 노치 영역은 오랫동안 조심스레 피해야 하는 어두운 금단의 구역에 불과했습니다. Notchikko는 이를 작은 섬으로 바꿔, 그 안에 작은 생명체가 자리 잡게 합니다 —— 당신이 Agent를 부르면 골똘히 생각에 잠기고, 도구가 호출될 때면 분주히 움직이며, 작업이 완료되면 조용히 기뻐합니다. 그리고 당신이 오래 자리를 비우면 꼬리를 말고 섬 한구석에서 조용히 졸기 시작합니다. 고개를 들면, 그곳에 그가 있습니다.

Notchikko는 AI Agent가 무엇을 하고 있는지 이해합니다. 설치된 CLI를 감지하고 조용히 묻습니다 —— "후크를 연결해 둘까요?" 그 이후로는 모든 것이 그를 통해 전달됩니다: 세션 시작, 도구 호출, 작업 완료, 오류, 일시 정지 —— 모든 움직임이 섬 위 작은 생명체의 동작으로 매핑됩니다. 화면 위에는 언제나 생기가 흐릅니다.

## 애니메이션 상태

Notchikko는 hook 이벤트를 통해 11가지 상태를 실시간으로 전환합니다. 각 상태는 여러 개의 SVG 변형을 포함할 수 있으며, 진입 시 무작위로 선택됩니다 —— 아래 표는 각 상태의 트리거와 대표 모습을 보여줍니다.

<table>
  <tr>
    <td align="center" width="120"><img src="assets/states/idle.svg" width="100"><br><sub><b>유휴</b></sub><br><sub>활동 없음</sub></td>
    <td align="center" width="120"><img src="assets/states/reading.svg" width="100"><br><sub><b>읽기</b></sub><br><sub>Read / Grep / Glob</sub></td>
    <td align="center" width="120"><img src="assets/states/typing.svg" width="100"><br><sub><b>입력</b></sub><br><sub>Edit / Write / NotebookEdit</sub></td>
    <td align="center" width="120"><img src="assets/states/building.svg" width="100"><br><sub><b>빌드</b></sub><br><sub>Bash</sub></td>
  </tr>
  <tr>
    <td align="center" width="120"><img src="assets/states/thinking.svg" width="100"><br><sub><b>사고</b></sub><br><sub>LLM 생성 중</sub></td>
    <td align="center" width="120"><img src="assets/states/sweeping.svg" width="100"><br><sub><b>정리</b></sub><br><sub>컨텍스트 압축</sub></td>
    <td align="center" width="120"><img src="assets/states/happy.svg" width="100"><br><sub><b>기쁨</b></sub><br><sub>작업 완료</sub></td>
    <td align="center" width="120"><img src="assets/states/error.svg" width="100"><br><sub><b>오류</b></sub><br><sub>도구 오류</sub></td>
  </tr>
  <tr>
    <td align="center" width="120"><img src="assets/states/sleeping.svg" width="100"><br><sub><b>수면</b></sub><br><sub>긴 유휴</sub></td>
    <td align="center" width="120"><img src="assets/states/approving.svg" width="100"><br><sub><b>승인</b></sub><br><sub>PermissionRequest</sub></td>
    <td align="center" width="120"><img src="assets/states/dragging.svg" width="100"><br><sub><b>드래그</b></sub><br><sub>사용자 드래그</sub></td>
    <td align="center" width="120"><sub>더 많은 변형은 테마 팩에</sub></td>
  </tr>
</table>

## 세션 동작

각 agent 세션은 `SessionStart`로 Notchikko의 시야에 들어와, 도구 호출 / 사고 / 승인 / 오류 / 완료를 거쳐 마지막으로 `Stop` 이벤트로 보관됩니다. 유휴와 수면은 타이머가 담당합니다. 라이프사이클은 다음과 같습니다:

```mermaid
stateDiagram-v2
    [*] --> 활성: SessionStart
    활성 --> 작업중: Tool / Prompt
    작업중 --> 승인대기: PermissionRequest
    승인대기 --> 작업중: Allow / Deny
    작업중 --> 완료: Stop
    완료 --> 유휴: 3s
    유휴 --> 수면: 60s / 120s
    수면 --> 작업중: 새 이벤트
    완료 --> [*]: 보관됨
```

승인 버블은 네 가지 동작을 제공합니다: 한 번 허용, 항상 허용, 이 세션은 자동 승인, 거부. Claude Code의 `AskUserQuestion`은 인식되어 클릭 가능한 옵션으로 렌더링됩니다.

Notchikko는 최대 32개의 세션을 동시에 마운트하며, 에이전트 간에 공유됩니다. 초과분은 LRU로 정리됩니다. 작은 생명체를 클릭하면 현재 세션이 실행 중인 터미널로 포커스가 이동하고, 우클릭 메뉴에서 임의의 세션을 고정 / 점프 / 닫기 할 수 있습니다. 토큰 사용량은 메뉴바에 동기화 표시됩니다.

## 지원과 제한

### CLI 지원

| CLI | Hook 통합 | 승인 버블 | 터미널 점프 | 토큰 사용량 | 상태 |
| --- | :---: | :---: | :---: | :---: | --- |
| **Claude Code** | ✓ | ✓ | ✓ | ✓ | 완전 지원 |
| **OpenAI Codex CLI** | ✓ | ✓ | ✓ | — | 완전 지원 |
| **Gemini CLI** | ✓ | ✓ | ✓ | — | 완전 지원 |
| **Trae CLI** | ✓ | ✓ | ✓ | — | 완전 지원 |
| Cursor Agent | — | — | — | — | 계획 중 |
| GitHub Copilot CLI | — | — | — | — | 계획 중 |
| opencode | — | — | — | — | 계획 중 |

✓는 지원됨, —는 아직 미지원입니다. 토큰 사용량은 현재 Claude Code의 transcript에서만 읽을 수 있습니다. 다른 agent가 동등한 필드를 노출하면 곧 따라잡습니다.

### 터미널 포커스

| 터미널 | 포커스 정밀도 |
| --- | --- |
| iTerm2 | Tab |
| Terminal.app | Tab |
| Ghostty | Tab |
| Kitty | Window |
| VS Code | Tab |
| VS Code Insiders | Tab |
| Cursor | Tab |
| Windsurf | Tab |
| 기타 터미널 | 앱 |

## 설치 및 실행

Notchikko는 macOS 14.0 이상이 필요합니다.

### 설치 패키지 다운로드

[Releases](https://github.com/yangjie-layer/Notchikko/releases)에서 서명 및 공증된 최신 `.dmg`를 다운로드하여 `/Applications`에 드래그한 후 실행하세요. 첫 실행 시 Notchikko는 설치된 AI CLI를 자동으로 감지하고 필요에 따라 hook 설치를 안내합니다.

### 소스에서 빌드

요구 사항: Xcode 15 이상, Swift 5; 외부 종속성 [Sparkle](https://github.com/sparkle-project/Sparkle)은 SPM으로 통합되어 있습니다.

```bash
git clone https://github.com/yangjie-layer/Notchikko.git
cd Notchikko
xcodebuild -scheme Notchikko -configuration Debug build
```

또는 Xcode에서 `Notchikko.xcodeproj`를 열고 `Notchikko` 스킴을 직접 실행할 수 있습니다.

## 사용자 정의 테마

Notchikko는 내장 캐릭터의 전체 교체를 지원합니다. SVG 세트를 상태별 디렉터리로 나누어 `~/.notchikko/themes/<your-theme>/`에 넣으세요:

```
~/.notchikko/themes/my-theme/
├── theme.json
├── idle/idle.svg
├── reading/reading.svg
├── typing/typing.svg
├── ...
└── sounds/        # 선택 사항: 상태별 짧은 효과음
```

각 상태 디렉터리에는 여러 변형을 둘 수 있으며, Notchikko는 진입할 때마다 무작위로 하나를 선택합니다. 외부 SVG는 자동으로 정화되며(`<script>`, `javascript:` 등 위험한 내용은 제거됨), 파일당 1 MB를 초과할 수 없습니다.

## 감사 및 라이선스

**Clawd 캐릭터 디자인은 [Anthropic](https://www.anthropic.com)에 귀속됩니다.** 본 프로젝트는 비공식 작품이며 Anthropic과는 공식적인 관계가 없습니다. 자동 업데이트는 [Sparkle](https://github.com/sparkle-project/Sparkle)에 의존합니다.

소스 코드는 MIT 라이선스로 공개되며, 자세한 내용은 [LICENSE](LICENSE)를 참조하세요. `assets/` 및 `Notchikko/Resources/themes/` 아래의 **아트워크는 MIT 라이선스에 해당하지 않습니다** —— 허락 없이 재배포하지 말아주세요.
