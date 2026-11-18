<%@ Page Language="C#" %>
<%@ Import Namespace="System.Web.Security" %>
<script runat="server">
    protected void Page_Load(object sender, EventArgs e)
    {
        if (!IsPostBack && Request.QueryString["saiu"] == "1")
            ShowInfo("Você saiu do Comunicador.");
    }

    protected void Entrar_Click(object sender, EventArgs e)
    {
        string error;
        ChatUser u = Auth.TryLogin(txtLogin.Text, txtSenha.Text, out error);
        if (u == null) { ShowError(error); return; }

        FormsAuthentication.SetAuthCookie(u.Login, false);
        Response.Redirect(u.MustChangePassword ? "ChangePassword.aspx" : "Chat.aspx", false);
        Context.ApplicationInstance.CompleteRequest();
    }

    void ShowError(string text) { litMsg.Text = "<div class=\"msg-box critical\">" + HttpUtility.HtmlEncode(text) + "</div>"; }
    void ShowInfo(string text)  { litMsg.Text = "<div class=\"msg-box good\">" + HttpUtility.HtmlEncode(text) + "</div>"; }
</script>
<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <script>(function(){try{var t=localStorage.getItem("comunicador-theme");if(t)document.documentElement.setAttribute("data-theme",t);}catch(e){}})();</script>
    <title>Entrar – Comunicador</title>
    <link rel="stylesheet" href="site.css" />
</head>
<body>
    <div class="corner"><button type="button" class="theme-toggle"></button></div>
    <div class="page narrow">
        <h1>Comunicador</h1>
        <p class="sub">Acesso restrito a usuários cadastrados.</p>
        <div class="card">
            <asp:Literal ID="litMsg" runat="server" />
            <form runat="server" ValidateRequestMode="Disabled" class="stack" defaultbutton="btnEntrar">
                <label>Usuário
                    <asp:TextBox ID="txtLogin" runat="server" MaxLength="50" autocomplete="username" autofocus="autofocus" />
                </label>
                <label>Senha
                    <asp:TextBox ID="txtSenha" runat="server" TextMode="Password" autocomplete="current-password" />
                </label>
                <asp:Button ID="btnEntrar" runat="server" Text="Entrar" CssClass="btn" OnClick="Entrar_Click" />
            </form>
        </div>
    </div>
    <script src="site.js"></script>
</body>
</html>
