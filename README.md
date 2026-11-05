# Kotoba Translate

PLaMo 3 Translate MLX専用の個人向けmacOS翻訳アプリ。SwiftUI + AppKit、ローカルPythonワーカー（mlx-lm）。Apple silicon / macOS 14以降 / Swift 6以降 / uvを使用。

## 起動

```sh
uv sync --python 3.12
swift run KotobaTranslate
```

Finderから起動するアプリを作成する場合:

```sh
zsh scripts/build-app.sh
open "dist/Kotoba Translate.app"
```

現在のCommand Line ToolsのmacOS 27.2 SDKでは`SwiftUIMacros`が欠けており、MarkdownUIの依存先でビルドエラーになります。この環境ではインストール済みの26.5 SDKを指定してビルドできます（作成済みアプリもこの指定を使用）。

```sh
zsh scripts/build-app.sh --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
```

Python環境はリポジトリ内の`.venv`を参照するため、このディレクトリは残してください。移動した場合は設定のPythonパスを更新するか、アプリを再ビルドしてください。

## リリース版のインストール

1. 起動中のKotoba Translateを⌘Qで終了します。
2. `dist/Kotoba Translate.app`をFinderで「アプリケーション」へコピーします。更新時は既存のアプリを置き換えます。
3. 「アプリケーション」から起動します。必要ならDockに追加してください。

作成済みの`.app`はリリースビルドです。インストーラーや`swift run`は不要です。Pythonはアプリに同梱せず、このリポジトリの`.venv`を参照します。インストール後もリポジトリと`.venv`を残してください。別のPython環境を使用する場合は設定のPythonパスを変更します。モデルの保存場所もそのまま参照するため、モデルは別途残してください。

アプリアイコンの原本は`Assets/AppIcon.png`に保存し、ビルド時に標準サイズの`.icns`を生成します。

## モデル

モデルはユーザーが別途ダウンロードします。公式の`pfnet/plamo-3-translate-{0.8b,2b,8b,31b}-MLX-4bit`など、PLaMo 3 TranslateのMLXモデルを使用してください。GGUFや元のTransformersの重みには対応しません。

「モデルを追加…」からローカルディレクトリを登録し、設定（⌘,）でタグを編集できます。モデルの重みだけでなく、tokenizer、`config.json`、`modeling_plamo_mlx.py`などモデルに付属するファイルも必要です。公式手順どおり`trust_remote_code=True`でディレクトリ内のPythonコードを読み込みます。翻訳実行中のHugging Faceアクセスはオフラインモードで無効化しています。

## 操作

- 原文・訳文の言語を選択。原文は自動検出も可能。公式の53言語に対応。
- Enterで翻訳、Shift+Enterで改行、⌘Enterでも翻訳。IME変換中のEnterは変換確定。
- 日本語への翻訳では「指定なし」「常体」「敬体」を選択。
- 「翻訳オプション」でContext、グローバル辞書の適用、Max tokens、Temperatureを指定。辞書の用語対は設定で編集。
- 下部の「オプション」ボタンで翻訳オプションを開閉。⌥⌘Oでも開閉。
- 設定の「文字」で原文・訳文それぞれのフォント、サイズ（10〜40pt）、書体、文字色を変更。「書体」には選択したフォントに実在するスタイル（ヒラギノのW3・W6、MenloのRegular・Boldなど）を表示し、その書体を直接使用します。フォントを変更した場合は新しいフォントの標準書体へ戻ります。文字色は「リセット」でシステム標準へ戻せます。設定は保存され、生テキストとMarkdownプレビューに反映。
- 原文下部に文字数と概算トークン数を表示。文字数は書記素単位。トークン数はCJK文字を約1.5トークン、それ以外をUTF-8の約4バイトで1トークンとして推定する目安。モデル・Python・tokenizerは使用しません。Context・辞書・指示トークンは含まないため、実際の入力トークン数・上限判定には使用しません。入力後150ms待ってバックグラウンドで集計。
- 原文・訳文の目のアイコンでMarkdown表示へ切り替え、テキストのアイコンで戻る。初期表示は生テキスト。MarkdownUI（swift-markdown-ui）を使用し、プレビューは選択時のみ生成。内容が変わらないプレビューは状態・統計の更新時に再解析しません。コピーは常に生テキスト。
- 翻訳オプション内でタグ名からモデルを選択。緑の点は読み込み中・読み込み済みを示し、「解放」でモデルを解放。設定の「一般」→「モデル」→「デフォルト」で起動時に選択するモデルを指定。未指定・削除済みの場合は先頭のモデルを選択します。選択だけではロードしません。
- 各テキスト欄の上に言語・プレビュー・消去／コピーを配置。下部に原文の文字数と生成統計を表示。訳文右上のボタンでコピー。原文・設定は生成中も編集可能で、実行中の翻訳には開始時点の値を使用。
- 「中止」はPythonプロセスごと終了しモデルを解放。途中までの訳文は残す。
- 設定で翻訳終了後の自動解放時間を選択。オプション内の「解放」でも即時解放。
- 読み込み中、入力処理進捗、生成中の訳文・トークン数・生成速度を表示。完了時の所要時間は読み込み・入力処理を含む。統計にカーソルを重ねると入力トークン数などを表示。Max tokensで切れた場合は「生成上限に到達」と表示。

アプリを開くだけではPythonもモデルも起動しません。同じモデルは解放まで再利用し、別のモデルやPython環境に切り替えた場合は次回翻訳時にワーカーを再起動します。生成時のKVキャッシュはリクエストごとに独立しています。履歴機能はありません。原文・訳文・Contextはディスクに保存せず、モデルの登録・辞書・Pythonパス・解放時間・デフォルトモデル・フォント設定（書体・文字色を含む）だけをUserDefaultsに保存します。

## 実装

Swift Packageとして構築し、MarkdownプレビューにMarkdownUIを使用します。HTTPサーバーは使いません。専用Pythonプロセスと標準入出力のJSON Linesで通信し、読み書き・推論はメインスレッド外で実行します。生成テキストは約20HzにまとめてUIへ反映します。中止・自動解放・アプリ終了時にはプロセスを終了してMLXメモリを解放します。

公式推奨のPFML3を直接構築し、`dataset=translation`、`source_lang`、`target_lang`、`context`、`glossary`、日本語限定の`form`を反映。BOSは1回だけ付加し、`<|plamo:tag|>`と`<|plamo:bos|>`を終了トークンに追加します。予約PFMLトークンを入力に含む場合はエラーにします。入力と生成上限の合計は32,768トークン以内に制限します。

依存バージョンは公式MLXモデルの`plamo_mlx_runtime`に合わせています。モデルを用いた実推論にはダウンロード済みのモデル一式が必要です。

仕様の参照元:

- [公式MLXモデル・仕様とオプション](https://huggingface.co/pfnet/plamo-3-translate-0.8b-MLX-4bit)
- [PFML3チャットテンプレート](https://huggingface.co/pfnet/plamo-3-translate-0.8b-MLX-4bit/blob/main/chat_template.jinja)
- [公式実行環境情報](https://huggingface.co/pfnet/plamo-3-translate-0.8b-MLX-4bit/blob/main/config.json)
- [mlx-lm](https://github.com/ml-explore/mlx-lm)
- [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui)
