<%@ Page Language="C#" %>
<%@ Import Namespace="System.Data.SqlClient" %>
<script runat="server">
    // Cria o PRIMEIRO administrador. Só funciona enquanto não existir nenhum
    // usuário no banco; depois disso, responde 404.
    static bool AnyUser()
    {
        using (var conn = Db.Open())
        using (var cmd = new SqlCommand("SELECT COUNT(*) FROM dbo.ChatUser", conn))
            return (int)cmd.ExecuteScalar() > 0;
    }

    protected void Page_Init(object sender, EventArgs e)
    {
        if (AnyUser())
        {
            Response.StatusCode = 404;
            Response.End();
        }
    }

    protected void Criar_Click(object sender, EventArgs e)
    {
        string login = txtLogin.Text.Trim(), nome = txtNome.Text.Trim();
        if (login.Length < 3 || nome.Length < 2) { ShowError("Informe usuário (mín. 3) e nome."); return; }
        if (txtSenha.Text.Length < Auth.MinPasswordLength) { ShowError("A senha deve ter pelo menos " + Auth.MinPasswordLength + " caracteres."); return; }
        if (txtSenha.Text != txtConfirma.Text) { ShowError("A confirmação não confere."); return; }

        using (var conn = Db.Open())
        {
            int id = Auth.CreateUser(conn, login, nome, txtSenha.Text, true);
            Auth.SetPassword(conn, id, txtSenha.Text, false);
        }
        Response.Redirect("Login.aspx", false);
        Context.ApplicationInstance.CompleteRequest();
    }

    void ShowError(string text) { litMsg.Text = "<div class=\"msg-box critical\">" + HttpUtility.HtmlEncode(text) + "</div>"; }
</script>
<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Configuração inicial – Comunicador</title>
    <link rel="stylesheet" href="site.css" />
</head>
<body>
    <div class="page narrow">
        <h1>Configuração inicial</h1>
        <p class="sub">Crie o primeiro administrador. Esta página deixa de existir depois disso.</p>
        <div class="card">
            <asp:Literal ID="litMsg" runat="server" />
            <form runat="server" ValidateRequestMode="Disabled" class="stack" defaultbutton="btnCriar">
                <label>Usuário (login)<asp:TextBox ID="txtLogin" runat="server" MaxLength="50" /></label>
                <label>Nome de exibição<asp:TextBox ID="txtNome" runat="server" MaxLength="100" /></label>
                <label>Senha<asp:TextBox ID="txtSenha" runat="server" TextMode="Password" autocomplete="new-password" /></label>
                <label>Confirme a senha<asp:TextBox ID="txtConfirma" runat="server" TextMode="Password" autocomplete="new-password" /></label>
                <asp:Button ID="btnCriar" runat="server" Text="Criar administrador" CssClass="btn" OnClick="Criar_Click" />
            </form>
        </div>
    </div>
</body>
</html>
