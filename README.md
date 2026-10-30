# Windows Temporary Profile Recovery

**Windows 10/11 · Active Directory / local accounts · PowerShell 5.1+**

Procedimento e script para diagnosticar e recuperar **perfis de usuário temporários** quando o Windows não consegue carregar o perfil original devido a problemas de permissões NTFS nos arquivos do Registro do usuário.

> **Segurança:** o script é **somente diagnóstico por padrão**. A opção `-Repair` exige PowerShell elevado, usuário afetado desconectado, backup obrigatório, verificações de segurança e uma confirmação digitada. Leia o procedimento antes de usar. O projeto é fornecido sem garantias.

## Sintomas

- O Windows entra em `C:\Users\TEMP.DOMINIO`, `TEMP.DOMINIO.000`, etc., em vez de carregar `C:\Users\usuario`.
- Reiniciar não resolve; novos perfis TEMP podem ser criados.
- O serviço **User Profile Service** registra erros como **1502, 1508, 1509, 1511 e 1515**.
- `icacls` pode retornar **Access is denied / Acesso negado** para `NTUSER.DAT`, `UsrClass.dat` ou arquivos `.LOG1` / `.LOG2`.
- No `ProfileList`, a chave SID original pode aparecer com o sufixo `.bak`.

O caso que motivou este repositório foi corrigido restaurando as permissões dos arquivos do hive e seus logs e, em seguida, corrigindo **apenas a entrada do SID afetado** no Registro. **A causa inicial das alterações de ACL não foi comprovada.** Não existe, neste projeto, confirmação de que alguma KB específica do Windows provoque esse problema.

## O que o script faz

1. Resolve o SID do usuário informado e confere a pasta original.
2. Exibe perfis `Win32_UserProfile`, chaves do `ProfileList` e permissões dos arquivos (modo diagnóstico).
3. Em `-Repair`, exige que o perfil esteja **descarregado** e que as pastas pai concedam controle total ao usuário, ao `SYSTEM` e aos Administradores.
4. Cria backup **com acesso restrito** a `SYSTEM` e Administradores: exportação do `ProfileList` e cópias com `robocopy /B /COPYALL` dos arquivos `NTUSER.DAT*` e `UsrClass.dat*`, incluindo logs transacionais.
5. Corrige a ACL herdada, com `takeown /A` e `icacls /reset`, **somente** em seis arquivos esperados, caso estejam presentes: os dois `.DAT` e respectivos `.LOG1`/`.LOG2`.
6. Se houver `.bak` apontando para o perfil original, remove **somente** a chave TEMP do mesmo SID (quando validada) e renomeia `.bak` para o SID normal. Define `State=0` e `RefCount=0` se este último existir.
7. Solicita reinício e validação manual. **Não apaga diretórios TEMP**, perfis originais ou backups.

## Requisitos

- Windows 10/11 64 bits, Windows PowerShell 5.1 ou superior, executado **como Administrador** (64 bits).
- O usuário afetado deve ter feito **logoff**, não apenas desconectado a sessão. Se necessário, reinicie e entre diretamente com outra conta administradora.
- Permissões corretas nas pastas pai (`C:\Users\usuario` e `...\AppData\Local\Microsoft\Windows`). O script **recusa a correção** se não encontrar controle total para o SID do usuário, SYSTEM e Administradores nas ACLs dessas pastas.
- Espaço livre para os arquivos de backup. **Faça também backup independente dos dados pessoais importantes** antes de qualquer reparação.
- Ambiente compatível com **perfis locais**. Não foi validado para FSLogix, perfis móveis (roaming), UPD, redirecionamento especial, EFS ou configurações corporativas personalizadas de ACL.

## Como executar

Baixe o repositório (Git clone ou ZIP), confira o conteúdo do script e abra o **Windows PowerShell como Administrador**. Não use `iex` para executar diretamente scripts da internet. Substitua `EXEMPLO\usuario` e `C:\Users\usuario` pelos valores da máquina.

### Se a execução for bloqueada por falta de assinatura digital

Se aparecer a mensagem **"o arquivo não está assinado digitalmente"**, você pode liberar a execução **somente na sessão atual** do PowerShell, desde que isso seja permitido pela política de segurança da sua organização.

Na **mesma janela** de PowerShell aberta como Administrador, execute:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
```

Depois, execute normalmente o comando de diagnóstico ou de correção abaixo. O parâmetro `-Scope Process` **não altera permanentemente** a política de execução do Windows: a liberação deixa de valer ao fechar essa sessão. Use esta opção **apenas após conferir a origem e o conteúdo do script**; ela não verifica se um script é seguro.

Se continuar bloqueado, confira as políticas aplicadas:

```powershell
Get-ExecutionPolicy -List
```

As políticas `MachinePolicy` e `UserPolicy`, geralmente definidas por GPO, têm precedência sobre `Process`. **Não tente contornar uma restrição imposta pela organização**; consulte o administrador responsável.

**1. Diagnóstico (não modifica arquivos nem Registro):**

```powershell
.\scripts\Repair-TemporaryProfile.ps1 -UserName 'EXEMPLO\usuario' -ProfilePath 'C:\Users\usuario'
```

**2. Correção, após analisar o diagnóstico:**

```powershell
.\scripts\Repair-TemporaryProfile.ps1 -UserName 'EXEMPLO\usuario' -ProfilePath 'C:\Users\usuario' -Repair
```

Após o backup, digite **`REPAIR`** quando solicitado para autorizar as alterações. Qualquer outra resposta cancela a correção sem alterar os arquivos originais ou o Registro. O backup já criado permanece para auditoria.

> **Segurança:** não é necessário desativar o antivírus, alterar globalmente a política de execução ou baixar executáveis adicionais. O `Bypass` mostrado acima é temporário e não substitui a verificação do script.

**3. Reinicie e entre com a conta recuperada. Valide:**

```powershell
$env:USERPROFILE
```

```powershell
Get-CimInstance Win32_UserProfile | Where-Object { $_.LocalPath -eq $env:USERPROFILE } | Select-Object LocalPath,Loaded,Status
```

O resultado esperado é o caminho **original**, `Loaded=True` e `Status=0`. Um segundo logoff/login ajuda a verificar a persistência da recuperação.

## Quando NÃO executar `-Repair`

- A conta do usuário ainda está conectada ou seu hive está carregado.
- O problema é de autenticação/AD, rede, disco, antivírus ou outra causa não relacionada a ACLs dos arquivos do hive.
- A chave `.bak` aponta para outra pasta, ou a chave normal do SID aponta para um local não reconhecido como TEMP.
- A pasta pai já tem permissões incorretas, contém entradas de negação ou utiliza ACLs especiais.
- Não é possível preservar um backup confiável.

Em qualquer uma dessas condições, o script deve **interromper sem tentar um conserto genérico**. Não faça alterações em massa em estações de trabalho apenas porque apresentam perfil temporário.

## Backup, reversão e limpeza

Os backups são gravados em:

```text
%ProgramData%\WindowsTempProfileRecovery\Backups\profile-<SID>-<data-hora>\
```

Incluem `ProfileList.reg`, arquivos do hive e logs; seus dados podem conter informações privadas. O backup é protegido com ACLs para `SYSTEM` e Administradores. **Não publique os arquivos de backup, hashes de nomes de usuários ou exportações do Registro em issues.**

Se a correção falhar, **não repita automaticamente a remoção/renomeação de chaves**: examine os novos eventos e o estado do Registro. O `.reg` é uma cópia de segurança, não um comando seguro de reversão automática, porque importa entradas de múltiplos usuários; a restauração deve ser seletiva e analisada por um administrador.

Depois de **dois logins bem-sucedidos** e backup dos dados pessoais, identifique pastas TEMP órfãs e remova-as manualmente **somente** se nenhum perfil ativo/WMI/Registro estiver associado a elas. O script não faz essa limpeza para evitar perda de dados.

## Estrutura

```text
windows-temp-profile-recovery/
├── .github/workflows/validate.yml
├── scripts/Repair-TemporaryProfile.ps1
├── tests/Test-Syntax.ps1
├── README.md
├── README.en.md
├── LICENSE
└── .gitignore
```

## Referências técnicas

- [Microsoft — Solucionar problemas de perfis de usuário pelos eventos](https://learn.microsoft.com/pt-br/troubleshoot/windows-server/user-profiles-and-logon/troubleshoot-user-profiles-events)
- [Microsoft — Win32_UserProfile: Loaded e Status](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/userprofileprov/win32-userprofile)
- [Microsoft — icacls](https://learn.microsoft.com/pt-br/windows-server/administration/windows-commands/icacls)
- [Microsoft — takeown](https://learn.microsoft.com/pt-br/windows-server/administration/windows-commands/takeown)
- [Microsoft — robocopy](https://learn.microsoft.com/pt-br/windows-server/administration/windows-commands/robocopy)

## Contribuições e licença

Issues e pull requests são bem-vindos, especialmente com reprodução em VMs de teste e logs **anonimizados**. Evite divulgar nomes de usuários, SIDs de domínio, nomes de máquinas ou informações pessoais.

Licenciado sob [MIT](LICENSE). Não há suporte oficial da Microsoft associado a este projeto.
