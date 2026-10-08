# Codenotch para Ubuntu

Um notch na borda da tela que mostra quanto do limite de uso do **Claude Code**, do **Codex** e do **Cursor** você já
gastou, e se cada sessão ainda está trabalhando ou esperando por você.

Este repo é um **port para Linux** do [Codenotch](https://github.com/vinzdg/codenotch), o app original para macOS
de [@vinzdg](https://github.com/vinzdg). Ele não copia o código do upstream: o `setup.sh` baixa o port Tauri que já
existe em `windows/` no repo original, aplica os módulos deste repo e compila.

## O que ele mostra

| Provedor | De onde vem |
|---|---|
| Claude Code | Limites de sessão e semanais, com o token que o Claude Code guarda em `~/.claude/.credentials.json`. Lista as sessões vivas pelos transcripts em `~/.claude/projects`. |
| Codex | Janelas de 5h e semanal com o login em `~/.codex/auth.json`. **Contas Enterprise/Business de workspace** não têm essas janelas: nelas o notch mostra o **limite mensal de crédito** (o mesmo que o `/status` do Codex chama de "Monthly credit limit"), com data de renovação. |
| Cursor | A sessão do próprio editor (`state.vscdb`). |

Provedores que não estão instalados ou logados simplesmente não ganham célula.

## Instalar

```bash
git clone <url-deste-repo> codenotch-linux
cd codenotch-linux
bash setup.sh                      # pede sudo (apt); 5 a 15 min no primeiro build
./app/scripts/doctor-linux.sh      # diagnóstico, só leitura
./app/scripts/run-linux.sh         # sobe o notch
```

Se você já tem Rust e as bibliotecas: `bash setup.sh --no-deps`. Sem Rust:
`curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`.

Rodadas seguintes reaproveitam o clone do upstream e o cache de build, então são rápidas.

Atalho no menu de aplicativos: `./app/scripts/install-desktop.sh`. Para iniciar com o sistema, ligue
"Start at sign-in" nas configurações do app (ou `./app/scripts/run-linux.sh autostart on`).

### Iniciar e reiniciar pelo terminal

O notch é um programa gráfico: rodar o `run-linux.sh` direto prende o terminal até o app fechar. Para ter um comando
que sobe (ou reinicia) o notch e devolve o prompt, ponha esta função no `~/.bashrc` (ou `~/.zshrc`),
ajustando o caminho:

```bash
unalias notch_start 2>/dev/null   # evita colidir com um alias antigo de mesmo nome
notch_start() {
  pkill -x codenotch              # para o notch, se estiver rodando
  while pgrep -x codenotch >/dev/null; do sleep 0.1; done   # espera ele sair (o app aceita uma instância só)
  setsid -f ~/codenotch-linux/app/scripts/run-linux.sh >/dev/null 2>&1
}
```

Depois, `source ~/.bashrc` e `notch_start`. Para só parar: `pkill -x codenotch`.

Detalhes que costumam dar problema:

- Use uma **função**, não um `alias`. Com `pkill ... && ...` o notch não sobe quando não há nada rodando (o `pkill`
  devolve erro), e definir uma função com o nome de um alias já existente dá `syntax error near unexpected token '('`.
  Se isso acontecer: `unalias notch_start`, apague o alias antigo do `~/.bashrc` e faça `source` de novo.
- `setsid -f` desliga o processo do terminal, então ele sobrevive ao fechamento da janela. A saída vai para
  `/dev/null` porque o app já grava o próprio log em `~/.config/codenotch/run.log`.

### Uso

- A pílula fica na borda direita da tela principal. Passe o mouse e o cartão abre.
- `Alt` + arrastar move o notch ao longo da borda.
- Clique numa sessão do cartão do Claude para trazer o terminal dela para a frente (veja "Limites").

## O que este repo acrescenta ao port do Windows

| Arquivo | O que faz |
|---|---|
| `overlay/linux_focus.rs` | Detecta a sessão (X11 / Wayland; GNOME, KDE, Sway, Hyprland) e implementa "pular para o terminal da sessão", que no upstream devolvia sempre `false` no Linux. |
| `overlay/codex_spend.rs` | Lê o limite mensal de gasto (`spend_control`) das contas de workspace do Codex e o mostra como uma janela de uso. |
| `setup.sh` | Baixa só o commit travado do upstream, aplica os módulos, roda os testes e compila. Falha com mensagem clara se o upstream mudou. |
| `scripts/` | Launcher (`run-linux.sh`), diagnóstico (`doctor-linux.sh`) e atalho de menu (`install-desktop.sh`). |

O `setup.sh` também corrige a entrada de autostart que o app grava, para que ela passe por `GDK_BACKEND=x11`, e o
caminho do `codenotch-hook`, que no upstream tinha `.exe` fixo e quebrava o "Let Claude Code notify Codenotch".

## Testes

```bash
cd app && cargo test --release -p codenotch -- linux_focus codex_spend    # 16 testes dos módulos novos
cd app && cargo test --release                                           # suíte inteira do upstream
```

## Se algo der errado

| Sintoma | O que tentar |
|---|---|
| Janela vazia ou preta | `CODENOTCH_WEBKIT_SAFE=1 ./app/scripts/run-linux.sh` (desliga o renderer DMA-BUF do WebKitGTK; comum com NVIDIA). |
| Fundo do notch não transparente | Precisa de compositor. No Ubuntu/GNOME já existe; em WMs leves, rode `picom`. |
| Sem ícone na bandeja (GNOME) | `sudo apt install gnome-shell-extension-appindicator`, saia e entre na sessão. |
| Anel do Claude em "Waiting for first reading..." | Normal nos primeiros instantes. Se persistir, veja `~/.config/codenotch/run.log`. |
| Anel do Codex em "—" | A conta pode não ter janelas nem limite de gasto. Veja `grep -i codex ~/.config/codenotch/run.log`. |
| `setup.sh` reclama de âncora no patch | O upstream mudou. Use o commit travado (padrão) ou ajuste o trecho indicado no erro. |
| Copilot sem leitura | O provider do upstream procura `gh.exe`. Contorno (não testado): `GH_TOKEN="$(gh auth token)" ./app/scripts/run-linux.sh`. |

## Testado em

- Ubuntu, sessão **X11**, com Claude Code, Codex (conta Enterprise) e Cursor: notch, anéis de uso e limite mensal
  do Codex funcionando.
- Os módulos novos têm testes unitários (16).

**Ainda não confirmado em uso real:** o "pular para o terminal" (a lógica tem testes, o clique em tela real ainda
não foi exercitado) e qualquer sessão **Wayland**.

## Limites

- **Wayland:** roda via XWayland, que posiciona a janela e a mantém no topo. "Pular para o terminal" deve funcionar
  no X11, no Sway e no Hyprland; no GNOME e no KDE em Wayland puro não há API para isso e o app apenas avisa.
- **Wayland nativo (gtk-layer-shell):** não implementado.
- **Terminais de processo único** (gnome-terminal, o padrão do Ubuntu; kitty/Ghostty em instância única): todas as
  janelas pertencem ao mesmo processo, então com várias abertas o "pular" pode trazer a janela errada, e nunca escolhe
  a aba.
- **tmux / screen:** o Claude roda como filho do servidor do multiplexador, não do terminal, então o "pular" não
  encontra janela.
- **Fora do escopo:** atualização automática, link com o celular e os recursos exclusivos do macOS.
- O cartão mostra a porcentagem e a data de renovação do limite mensal, mas não o valor em dólares.

## Privacidade

O app lê credenciais e transcritos **locais** (os mesmos que o Claude Code, o Codex e o Cursor já guardam). Pelo que
o código mostra, as únicas requisições de rede são aos endpoints de uso desses provedores e à API de releases do
GitHub. Isso vem de uma leitura do código, **não de uma auditoria formal**, e a lógica de rede é do upstream:
consulte-o antes de confiar.

## Créditos e licença

- App original (macOS): [vinzdg/codenotch](https://github.com/vinzdg/codenotch), MIT © Vinz.
- Port Tauri para Windows, base deste: `windows/` no repo acima, desenvolvido em
  [Im-Midi/codenotch-windows](https://github.com/Im-Midi/codenotch-windows).
- Os ícones dos provedores vêm do upstream e são marcas de seus donos.
- O código deste repo (módulos em `overlay/` e scripts) é MIT. Veja `LICENSE`.
