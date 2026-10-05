# mac-use (Português do Brasil)

Read this in: [English](README.md)

### Por que usar o mac-use?

O mac-use foi feito para conviver com o uso normal do Mac e com outras ferramentas de controle do computador que sejam compatíveis. Em janelas nativas, ele atua pela Acessibilidade na janela exata que você escolheu, sem ativá-la nem mover o cursor físico. Ele espera a atividade recente do teclado ou do mouse terminar e para quando você assume o controle. O bloqueio compartilhado coordena as ações com outras ferramentas que respeitam o mesmo bloqueio, incluindo o RemoteCode. Não é possível garantir que ferramentas que ignoram esse bloqueio não entrem em conflito. No Chrome, o mac-use abre abas em segundo plano e deixa de controlá-las assim que você as seleciona.

### O que você precisa

- macOS 14 ou mais recente
- Xcode Command Line Tools (`xcode-select --install`)
- Um cliente MCP: Distill, Codex, Claude Code ou Grok Build
- Google Chrome somente se você quiser usar as ferramentas do navegador

### 1. Compile o servidor MCP

Abra o Terminal e execute:

```sh
git clone git@github.com:samuelfaj/mac-use.git
cd mac-use
swift build -c release
```

Se você não usa SSH do GitHub, substitua o primeiro comando pela URL que costuma usar. Mantenha essa pasta no mesmo lugar depois da instalação. Os clientes MCP abaixo iniciam o mesmo executável dentro dessa pasta.

### 2. Conecte ao seu cliente MCP

Execute **apenas um** comando, de acordo com o cliente que você usa, dentro da pasta `mac-use`:

- **Distill:**

  ```sh
  distill mcp add mac-use -- "$(pwd)/.build/release/mac-use-mcp"
  distill mcp doctor mac-use
  ```

- **Codex:**

  ```sh
  codex mcp add mac-use -- "$(pwd)/.build/release/mac-use-mcp"
  ```

- **Claude Code:**

  ```sh
  claude mcp add --scope user mac-use -- "$(pwd)/.build/release/mac-use-mcp"
  ```

- **Grok Build:**

  ```sh
  grok mcp add --scope user mac-use -- "$(pwd)/.build/release/mac-use-mcp"
  ```

Se o cliente já estiver aberto, reinicie-o depois de adicionar o servidor. No Claude Code, aprove o servidor se aparecer uma solicitação. Mantenha o repositório no mesmo caminho; cada cliente inicia o executável a partir dele.

### Instale a skill do agente globalmente

Instale a [skill mac-use](skills/mac-use/SKILL.md) incluída neste repositório para Codex, Claude Code e Distill/Grok Build (que compartilham `~/.grok/skills`):

```sh
for root in "$HOME/.codex/skills" "$HOME/.claude/skills" "$HOME/.grok/skills"; do
  mkdir -p "$root/mac-use"
  cp "skills/mac-use/SKILL.md" "$root/mac-use/SKILL.md"
done
```

Inicie uma nova sessão do cliente após instalar. A skill exige fechar os recursos criados pelo agente inclusive em caso de erro, preservar os recursos do usuário e verificar a limpeza. O MCP também fornece um lembrete. São instruções para o agente, não um isolamento automático; o perfil compartilhado do Chrome mantém histórico e dados dos sites.

### 3. Permita o acesso do macOS às janelas nativas

Quando o macOS solicitar, permita **Acessibilidade** e **Gravação de Tela** para o aplicativo que inicia seu cliente MCP. Essas permissões são necessárias apenas para controlar janelas nativas do macOS. Você pode usar a ferramenta MCP `doctor` em uma janela para verificar as permissões.

### 4. Opcional: configure o Chrome

A extensão do Chrome está incluída neste repositório. Carregue-a no mesmo perfil do Chrome que pretende usar com o mac-use:

1. Abra `chrome://extensions`.
2. Ative o **Modo do desenvolvedor**.
3. Clique em **Carregar sem compactação** e selecione a pasta `chrome-extension` dentro da pasta clonada `mac-use`.
4. Abra os detalhes da extensão e copie o **ID** de 32 letras. A imagem mostra onde encontrá-lo.

   ![Página de detalhes da extensão do Chrome com o ID destacado](docs/images/chrome-extension-id.jpg)

5. No Terminal, dentro da pasta `mac-use`, registre a extensão com o host nativo. Troque o ID de exemplo pelo ID exibido no Chrome:

   ```sh
   .build/release/mac-use-mcp install-chrome-host SEU_ID_DE_32_LETRAS
   ```

6. Clique no ícone da extensão mac-use no Chrome. O indicador deve mostrar **ON**. A extensão se conecta sozinha e reconecta automaticamente a cada 30 segundos se cair; o clique só força uma nova tentativa imediata. No seu cliente MCP, chame `browser_status`; a resposta deve incluir `connected: true`.

A extensão usa o sistema de mensagens nativas do Chrome para se conectar ao servidor MCP. Se você mover o repositório ou recarregar a extensão e o ID mudar, execute novamente o comando de registro com o caminho ou ID atualizado. Use uma janela normal do Chrome, não o modo anônimo.

### Teste

- Para uma janela nativa, chame `list_windows` e use os dados exatos da janela com as ferramentas correspondentes do mac-use.
- Para o Chrome, chame `browser_status` e depois `browser_open` com um endereço `http://` ou `https://`. Uma nova aba será aberta em segundo plano. As abas abertas pelo mac-use são colocadas em um grupo de abas recolhido chamado "mac-use"; mover uma aba para fora do grupo ou selecioná-la devolve o controle a você. Use `browser_snapshot` para conferir a página e `browser_act` para executar as ações disponíveis.

`distill mcp doctor` verifica se o servidor MCP inicia e disponibiliza as ferramentas. Ele não verifica as permissões do macOS nem a conexão com o Chrome.

### Opcional: use cua Spaces quando disponível

Se a CLI do [cua](https://github.com/trycua/cua) estiver instalada (`curl -fsSL https://cua.ai/install.sh | sh` e depois `cua auth login`), a ferramenta somente leitura `cua_status` lista seus [cua Spaces](https://spaces.cua.ai/). Os agentes devem preferir um Space, pelo servidor MCP `cua`, para tarefas que não precisam dos seus próprios apps, arquivos ou sessões logadas, assim seu Mac não é mexido. O mac-use apenas detecta os Spaces; ele não os controla. Se o `cua` estiver fora do `PATH` do cliente MCP, defina `CUA_BIN` com o caminho completo.

### Jev e o LLM da sessão

`jev_decide` sugere um passo. Com `JEV_API_KEY`, `TYPESAFE_API_KEY` ou `OPENROUTER_API_KEY`, o Jev responde e a resposta também traz até três `alternatives`, seus `signals` (`complete`, `consequential`, `authorized`) e um `reason` quando retorna `BLOCKED`, para o LLM da sessão conferir a sugestão ou perguntar a você. Sem chave, retorna candidatos seguros para o LLM da sessão escolher. Se uma chamada ao Jev configurado falhar, a ferramenta retorna erro em vez de trocar em silêncio. Nenhum dos dois caminhos clica em nada.

### Ferramentas de janelas nativas

- `click_element` e `set_value` aceitam `element_id` (o id `ax_<n>` do `get_ui_tree` cujo token você passa) ou `role` mais `label`, nunca os dois. `set_value` preenche campos e combos, ajusta sliders e caixas de seleção e escolhe itens de menus pop-up. `menu_shortcut` aciona o item de menu habilitado associado a um atalho como `MOD+S`.
- `get_ui_tree` aceita `ocr: auto|always|never`. O texto OCR é anexado após a árvore em uma linha `ocr:` e exige permissão de Gravação de Tela; sem ela, a árvore volta com um `ocr_error`.
- Janelas minimizadas e apps ocultos funcionam com as ferramentas somente AX (`get_ui_tree`, `click_element`, `set_value`, `menu_shortcut`). Ferramentas de ponteiro e teclado precisam de `restore_window` antes.
- As mutações esperam a interface estabilizar e retornam uma observação nova com `settle_ms` e `settled`.
- `jev_decide` também aceita `allowed_risks` (`delete`, `send`, `purchase`, `close`: controles dessas categorias ficam ocultos, a menos que listados), `min_confidence` e `min_margin` (0 a 1).
- `run_subtask` exige uma chave do Jev. Passe `goal`, `verification` (lista não vazia) e, opcionalmente, `constraints`, `inputs`, `max_actions` (padrão 30), `shortcuts`, `allowed_risks`, `secret_inputs` (chaves de `inputs` digitadas mas nunca mostradas ao Jev nem retornadas), `dry_run`, `min_confidence`, `min_margin`. Ele observa, pede um passo ao Jev, age e repete; retorna `SUBTASK_COMPLETE`, `BLOCKED`, `NEEDS_INPUT`, `NEEDS_AGENT` ou `DRY_RUN`. O texto digitado vem somente de `inputs`.
- Extensão do Chrome: `browser_act` espera a página estabilizar e retorna um snapshot novo, então os `ref` anteriores ficam obsoletos. Também trata opções de select e preenchimento, ignora elementos cobertos e informa mudanças em regiões ao vivo.

### Se o Chrome mostrar "Specified native messaging host not found"

O registro do host nativo está ausente ou não corresponde ao ID da extensão. Na pasta `mac-use`, execute novamente o comando de registro com o ID atual de `chrome://extensions`. Depois, clique no ícone da extensão para conectar. Confira se `.build/release/mac-use-mcp` continua no mesmo caminho e se a extensão está carregada no perfil do Chrome que você está usando.

### Privacidade e controle

A extensão do Chrome pode ler o texto das páginas e os valores dos formulários, exceto senhas. Ela pode clicar, preencher campos, digitar e rolar em abas que abriu. Ela não controla a aba selecionada; ao selecionar uma aba automatizada, você retoma o controle. Quando `browser_close` é chamado ou a extensão se desconecta, ela tenta fechar somente as abas que criou e que ainda aparentam estar inativas e não terem sido selecionadas pelo usuário. O Chrome não torna atômicas a verificação de atividade e a remoção da aba; portanto, uma seleção que coincida com a remoção ainda pode resultar no fechamento. O conteúdo e as capturas das páginas ficam visíveis para a sessão do Distill. Não use essas ferramentas em páginas com informações que você não queira compartilhar com essa sessão. A extensão solicita acesso a sites HTTP e HTTPS para poder operar nas páginas que você pedir para abrir.

### Agradecimentos

Obrigado a [shhivv](https://github.com/shhivv) e ao [arc-cua](https://github.com/shhivv/arc-cua), a inspiração para `run_subtask`, `set_value`, `menu_shortcut`, `allowed_risks`, `secret_inputs`, percepção por OCR, estabilização da interface e ids de elementos.
