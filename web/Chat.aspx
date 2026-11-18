<%@ Page Language="C#" %>
<script runat="server">
    protected ChatUser me;
    protected void Page_Init(object sender, EventArgs e) { me = Auth.Require(Context); }
</script>
<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <script>(function(){try{var t=localStorage.getItem("comunicador-theme");if(t)document.documentElement.setAttribute("data-theme",t);}catch(e){}})();</script>
    <title>Comunicador</title>
    <link rel="stylesheet" href="site.css?v=2" />
</head>
<body>
    <div class="chat" id="chat" data-me="<%= me.UserId %>">
        <aside class="sidebar">
            <div class="sidebar-head">
                <div class="me"><%= HttpUtility.HtmlEncode(me.DisplayName) %></div>
                <div class="links">
                    <a href="ChangePassword.aspx">Alterar senha</a>
                    <% if (me.IsAdmin) { %><a href="admin/Users.aspx">Usuários</a><% } %>
                    <a href="Logout.aspx">Sair</a>
                    <button type="button" class="icon-btn" id="soundBtn" title="Silenciar sons">&#128266;</button>
                    <button type="button" class="theme-toggle"></button>
                </div>
            </div>
            <ul class="conv-list" id="convList"></ul>
        </aside>

        <main class="main" id="main">
            <div class="main-head">
                <button type="button" class="btn secondary small back-btn" id="backBtn">&larr;</button>
                <span class="title" id="convTitle">Geral</span>
                <span class="hint" id="convHint"></span>
            </div>
            <div class="messages" id="messages" aria-live="polite"></div>
            <div class="typing-line" id="typingLine"></div>
            <div class="status-line" id="statusLine"></div>
            <form class="composer" id="composer" autocomplete="off">
                <div class="tools">
                    <button type="button" class="tool-btn" id="emojiBtn" title="Emojis">&#128522;</button>
                    <button type="button" class="tool-btn" id="attachBtn" title="Enviar arquivo ou imagem (máx. 5 MB) — também dá para colar (Ctrl+V) ou arrastar">&#128206;</button>
                    <button type="button" class="tool-btn" id="buzzBtn" title="Tocar a campainha do colega">&#128276;</button>
                </div>
                <textarea id="msgInput" maxlength="2000" placeholder="Escreva uma mensagem… (Enter envia, Shift+Enter quebra linha)"></textarea>
                <button type="submit" class="btn">Enviar</button>
                <input type="file" id="fileInput" hidden />
                <div class="emoji-pop" id="emojiPop" hidden></div>
            </form>
        </main>
    </div>
    <script src="site.js"></script>
    <script src="chat.js?v=2"></script>
</body>
</html>
