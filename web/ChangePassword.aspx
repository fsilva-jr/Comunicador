<%@ Page Language="C#" %>
<script runat="server">
    ChatUser me;

    protected void Page_Init(object sender, EventArgs e)
    {
        me = Auth.Require(Context, adminOnly: false, allowMustChange: true);
        ViewStateUserKey = me.Login; // proteção contra CSRF nos postbacks
    }

    protected void Page_Load(object sender, EventArgs e)
    {
        if (!IsPostBack && me.MustChangePassword)
            litMsg.Text = "<div class=\"msg-box good\">Primeiro acesso: defina uma senha pessoal para continuar.</div>";
        lnkVoltar.Visible = !me.MustChangePassword;
    }

    protected void Salvar_Click(object sender, EventArgs e)
    {
        string error;
        if (Auth.TryLogin(me.Login, txtAtual.Text, out error) == null) { ShowError("Senha atual incorreta."); return; }
        if (txtNova.Text.Length < Auth.MinPasswordLength) { ShowError("A nova senha deve ter pelo menos " + Auth.MinPasswordLength + " caracteres."); return; }
        if (txtNova.Text != txtConfirma.Text) { ShowError("A confirmação não confere com a nova senha."); return; }
        if (txtNova.Text == txtAtual.Text) { ShowError("A nova senha deve ser diferente da atual."); return; }

        using (var conn = Db.Open()) Auth.SetPassword(conn, me.UserId, txtNova.Text, false);
        Response.Redirect("Chat.aspx", false);
        Context.ApplicationInstance.CompleteRequest();
    }

    void ShowError(string text) { litMsg.Text = "<div class=\"msg-box critical\">" + HttpUtility.HtmlEncode(text) + "</div>"; }
</script>
<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <script>(function(){try{var t=localStorage.getItem("comunicador-theme");if(t)document.documentElement.setAttribute("data-theme",t);}catch(e){}})();</script>
    <title>Alterar senha – Comunicador</title>
    <link rel="stylesheet" href="site.css" />
</head>
<body>
    <div class="corner"><button type="button" class="theme-toggle"></button></div>
    <div class="page narrow">
        <div class="nav"><asp:HyperLink ID="lnkVoltar" runat="server" NavigateUrl="Chat.aspx">&larr; Voltar ao chat</asp:HyperLink></div>
        <h1>Alterar senha</h1>
        <p class="sub"><%= HttpUtility.HtmlEncode(me.DisplayName) %> (<%= HttpUtility.HtmlEncode(me.Login) %>)</p>
        <div class="card">
            <asp:Literal ID="litMsg" runat="server" />
            <form runat="server" ValidateRequestMode="Disabled" class="stack" defaultbutton="btnSalvar">
                <label>Senha atual
                    <asp:TextBox ID="txtAtual" runat="server" TextMode="Password" autocomplete="current-password" />
                </label>
                <label>Nova senha (mín. 8 caracteres)
                    <asp:TextBox ID="txtNova" runat="server" TextMode="Password" autocomplete="new-password" />
                </label>
                <label>Confirme a nova senha
                    <asp:TextBox ID="txtConfirma" runat="server" TextMode="Password" autocomplete="new-password" />
                </label>
                <asp:Button ID="btnSalvar" runat="server" Text="Salvar" CssClass="btn" OnClick="Salvar_Click" />
            </form>
        </div>
    </div>
    <script src="site.js"></script>
</body>
</html>
