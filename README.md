# MemProbe

Um app de teste minúsculo para iOS. Ele confere se o iPhone aceita o jeito como o runtime do
[pes2017-recomp](https://github.com/dzakyraf/pes2017-recomp) organiza a memória, antes de começarmos
o porte. O app não contém nada do jogo.

O que ele testa:

1. **Aparelho:** modelo, versão do iOS, RAM, memória disponível para o app e quais permissões de memória
   (entitlements) o perfil de instalação deu.
2. **Espaço de endereço:** se dá para reservar os 4 GB que o jogo exige e qual é a maior reserva possível.
3. **Banco físico:** 512 MB visíveis em três endereços ao mesmo tempo, testado de dois jeitos
   (Mach `vm_remap` e arquivo compartilhado).
4. **Vigia de escrita:** proteção de páginas com `mprotect` e captura de `SIGSEGV`/`SIGBUS`, que o
   renderizador usa.
5. **Teste de carga** (botão): ocupa memória aos poucos até o iOS fechar o app, para saber o limite real.

## Como gerar o .ipa (sem Mac)

O GitHub Actions compila o app num Mac na nuvem a cada `git push`. Este repositório pode ser
**público**, porque não tem nada do jogo, e em repositório público os minutos de macOS são gratuitos.

1. Crie o repositório no GitHub (vazio, sem README) e envie este código.
2. Abra a aba **Actions** → execução "Build MemProbe.ipa" → baixe o artefato **MemProbe-ipa**
   (vem um `.zip` com o `MemProbe.ipa` dentro).

## Como instalar no iPhone (pelo Windows)

Com o **Sideloadly** (mais simples) ou o **AltStore** (2.2 ou mais novo):

1. Conecte o iPhone pelo cabo e confie no computador.
2. Arraste o `MemProbe.ipa` para o programa e entre com o seu Apple ID.
3. No iPhone: **Ajustes → Privacidade e Segurança → Modo de Desenvolvedor** (ative e reinicie) e
   **Ajustes → Geral → VPN e Gerenciamento de Dispositivo** → confie no seu Apple ID.
4. Abra o MemProbe. Os testes rodam sozinhos; toque em **Copiar** e cole o resultado na conversa.
5. Depois toque em **Teste de carga**. O app vai fechar (isso é esperado). Abra de novo e copie o
   relatório outra vez.

O relatório também fica salvo no app **Arquivos** → No Meu iPhone → MemProbe → `relatorio.txt`.
