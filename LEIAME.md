# Comunicador

Chat interno simples via browser (sala geral e conversas 1:1), para até 20 usuários.
Mesma base do AXMonitor: ASP.NET Web Forms no IIS, SQL Server e um job do SQL Agent.

## Estrutura

```
sql\Install-Database.sql   banco "Comunicador", tabelas, permissões e job de limpeza diária
web\Web.config             connection string + Forms Authentication
web\Login.aspx             login
web\Setup.aspx             cria o 1º administrador (só funciona com o banco vazio)
web\Chat.aspx + chat.js    tela do chat (polling a cada 3 s)
web\Api.ashx               API JSON (poll / send)
web\ChangePassword.aspx    troca de senha (obrigatória no primeiro acesso)
web\admin\Users.aspx       cadastro e gestão de usuários (somente admin)
web\App_Code\Auth.cs       acesso ao banco, hash de senha (PBKDF2) e sessão
```

## Instalação

1. **Banco:** em `sql\Install-Database.sql`, troque `@AppPoolIdentity` pela identidade
   do Application Pool e execute o script no SQL Server (como sysadmin).
2. **IIS:** crie um Application Pool `Comunicador` (.NET CLR v4.0, Integrated) e uma
   **Aplicação** apontando para `C:\Comunicador\web`. Mantenha a autenticação
   **Anonymous** habilitada e Windows Authentication desabilitada (o login é do próprio site).
3. **Web.config:** ajuste `Server=CHANGE_ME\CHANGE_ME` na connection string.
4. **HTTPS:** configure um binding HTTPS e mude `requireSSL="true"` no `Web.config`.
   Sem HTTPS, senhas e mensagens trafegam abertas na rede.
5. Acesse `https://servidor/Comunicador/Setup.aspx` e crie o primeiro administrador.
6. Em **Usuários**, cadastre os demais. Cada cadastro gera uma senha temporária, que
   deve ser entregue ao usuário. Ele troca a senha no primeiro acesso.

## Regras de funcionamento

- Mensagens são apagadas diariamente às 00:05 (job `Comunicador - Limpeza diaria`).
  O admin também pode apagar tudo na hora, em Usuários.
- 5 senhas erradas seguidas bloqueiam a conta por 15 minutos (o admin pode desbloquear).
- Usuários são desativados, nunca excluídos. Um usuário desativado perde o acesso na hora.
- "Online" significa atividade nos últimos 20 segundos (página do chat aberta).
- Limite de 20 usuários ativos (`MaxActiveUsers` em `admin\Users.aspx`).

## v2: campainha, emojis, arquivos, "digitando"

- **🔔 Campainha** (só em conversa 1:1): toca um "ding-dong" e sacode a janela do colega.
  Pode tocar de novo para a mesma pessoa só depois de 15 s.
- **😊 Emojis:** seletor no compositor. Mensagem só com emojis aparece grande.
- **📎 Arquivos e imagens** até 5 MB: pelo botão, colando (Ctrl+V, ótimo para prints) ou
  arrastando para a conversa. Imagens PNG/JPG/GIF/WebP aparecem como miniatura; os demais
  arquivos viram link de download. Ficam na tabela `ChatFile` e são apagados junto com as
  mensagens na limpeza diária.
- **"Fulano está digitando…"**, guardado só na memória do servidor, sem banco.
- **Som de nova mensagem** quando a conversa não está aberta; o botão 🔊/🔇 silencia.
  O navegador só libera áudio depois que a pessoa clica ou digita na página.

Para atualizar uma instalação v1: execute `sql\Upgrade-v2.sql`, copie os arquivos e acrescente
ao Web.config do servidor o `maxRequestLength="7168"` no `<httpRuntime>` e o bloco
`<security><requestFiltering><requestLimits maxAllowedContentLength="7340032" />` em `<system.webServer>`.

## Limitações conhecidas

- Quem administra o servidor ou o SQL Server pode ler a tabela `ChatMessage`.
  Backups e logs feitos durante o dia podem conter mensagens.
- Mensagens apagadas pelo admin continuam na tela de quem está com o chat aberto,
  até a página ser recarregada.
