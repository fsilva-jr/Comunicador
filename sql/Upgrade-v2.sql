/* =====================================================================
   Comunicador v2 - campainha, arquivos/imagens
   Execute UMA vez no banco Comunicador já existente (pode repetir sem erro).
   Instalações novas: Install-Database.sql já inclui estas alterações.
   ===================================================================== */
USE Comunicador;
GO

-- Tipo da mensagem: 0 = texto, 1 = campainha, 2 = arquivo
IF COL_LENGTH('dbo.ChatMessage', 'Kind') IS NULL
    ALTER TABLE dbo.ChatMessage ADD Kind TINYINT NOT NULL
        CONSTRAINT DF_ChatMessage_Kind DEFAULT 0 WITH VALUES;
GO

-- Arquivos anexados. ON DELETE CASCADE: a limpeza diária (DELETE em
-- ChatMessage) e o botão "Apagar todas as mensagens" levam os arquivos junto.
IF OBJECT_ID('dbo.ChatFile') IS NULL
CREATE TABLE dbo.ChatFile (
    FileId      BIGINT IDENTITY(1,1) PRIMARY KEY,
    MessageId   BIGINT NOT NULL
                CONSTRAINT FK_ChatFile_Message REFERENCES dbo.ChatMessage(MessageId) ON DELETE CASCADE,
    FileName    NVARCHAR(255) NOT NULL,
    ContentType VARCHAR(100)  NOT NULL,
    Size        INT           NOT NULL,
    Data        VARBINARY(MAX) NOT NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_ChatFile_MessageId')
    CREATE INDEX IX_ChatFile_MessageId ON dbo.ChatFile (MessageId);
GO
