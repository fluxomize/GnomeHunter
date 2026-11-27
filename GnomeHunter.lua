-- GnomeHunter v2.6.0 - eventos configuráveis com data/hora início + duração (BRT)
-- Estratégia de kill baseada no Spy (WoW Forever / Interface 16001)

local BOOT = CreateFrame("Frame")
BOOT:RegisterEvent("ADDON_LOADED")
BOOT:SetScript("OnEvent", function(self, event, loadedName)
    if event ~= "ADDON_LOADED" or loadedName ~= "GnomeHunter" then return end
    self:UnregisterEvent("ADDON_LOADED")

    -- =================================================================
    -- Constantes
    -- =================================================================
    local ADDON_PREFIX   = "GNMHUNT"
    local VERSION        = "2.6.0"
    local BOUNTY_BONUS   = 10    -- pontos extras pelo bounty de player
    local GUILD_BONUS    = 1     -- pontos extras por matar qualquer um da guild bounty
    local ALERT_COOLDOWN = 60    -- segundos entre alertas do mesmo nome
    local MAX_PUBLISH    = 20    -- máximo de linhas de ranking no /gnomo publish

    -- Eventos
    local EVENT_NAME_MAX_LEN   = 40    -- limite de caracteres do nome
    local EVENT_MAX_DURATION_H = 168   -- máximo de 7 dias (168h) por evento
    local EVENT_HISTORY_MAX    = 5     -- quantos eventos encerrados manter em histórico
    local KILLLOG_MAX          = 5000  -- rolling buffer local de kills

    -- Brasília = UTC-3, sem horário de verão desde 2019
    local BRT_OFFSET = -3 * 3600

    -- Ranking semanal: vira toda terça às 12:00 de Brasília (UTC-3, sem horário de
    -- verão) = terça 15:00 UTC. Âncora: terça 2024-01-02 15:00:00 UTC.
    -- Usamos o relógio do SERVIDOR (GetServerTime) pra todos os clientes
    -- da guild concordarem sobre qual é a semana atual.
    local WEEK_SECONDS   = 7 * 24 * 60 * 60
    local WEEK_ANCHOR    = 1704207600

    -- =================================================================
    -- DB
    -- =================================================================
    GnomeHunterDB = GnomeHunterDB or {}
    GnomeHunterDB.kills  = GnomeHunterDB.kills  or {}   -- pontos (com bônus de bounty)
    GnomeHunterDB.kcount = GnomeHunterDB.kcount or {}   -- kills brutos (1 por kill, sem bônus)
    GnomeHunterDB.opts   = GnomeHunterDB.opts   or {}
    -- Migração: se kcount vazio e kills populado, aproxima kcount como se tudo valesse 1pt
    for name, pts in pairs(GnomeHunterDB.kills) do
        if GnomeHunterDB.kcount[name] == nil then
            GnomeHunterDB.kcount[name] = pts
        end
    end
    if GnomeHunterDB.opts.guildOnly     == nil then GnomeHunterDB.opts.guildOnly     = false end
    if GnomeHunterDB.opts.bountyAlerts  == nil then GnomeHunterDB.opts.bountyAlerts  = true  end
    if GnomeHunterDB.opts.announce      == nil then GnomeHunterDB.opts.announce      = true  end
    if GnomeHunterDB.opts.announceDeath == nil then GnomeHunterDB.opts.announceDeath = false end
    if GnomeHunterDB.opts.rankView ~= "all" then GnomeHunterDB.opts.rankView = "week" end

    -- Ranking semanal: mesma estrutura do geral (kills = pts, kcount = kills brutos),
    -- mais o weekId da semana a que esses números pertencem.
    GnomeHunterDB.weekly        = GnomeHunterDB.weekly        or {}
    GnomeHunterDB.weekly.weekId = GnomeHunterDB.weekly.weekId or -1
    GnomeHunterDB.weekly.kills  = GnomeHunterDB.weekly.kills  or {}
    GnomeHunterDB.weekly.kcount = GnomeHunterDB.weekly.kcount or {}
    -- Migração: força off pra quem já estava com announceDeath ligado por padrão em v2.4.15
    if not GnomeHunterDB.migratedDeathOff then
        GnomeHunterDB.opts.announceDeath = false
        GnomeHunterDB.migratedDeathOff = true
    end

    -- player bounty: { name, race, setBy, setAt }
    GnomeHunterDB.bounty          = GnomeHunterDB.bounty          or nil
    GnomeHunterDB.bountyClearedAt = GnomeHunterDB.bountyClearedAt or 0

    -- guild bounty: { name (= nome da guild), setBy, setAt }
    GnomeHunterDB.guildBounty          = GnomeHunterDB.guildBounty          or nil
    GnomeHunterDB.guildBountyClearedAt = GnomeHunterDB.guildBountyClearedAt or 0

    GnomeHunterDB.minimap = GnomeHunterDB.minimap or { angle = 0.45, hide = false }
    GnomeHunterDB.resetAt = GnomeHunterDB.resetAt or 0

    -- Eventos
    -- GnomeHunterDB.events[eventId] = {
    --   id, name, startAt, endAt, setBy, setAt,  (metadata)
    --   kills  = { [player] = pts  },            (agregado sincronizado)
    --   kcount = { [player] = kcnt },
    --   finished = bool, cancelled = bool,
    -- }
    GnomeHunterDB.events          = GnomeHunterDB.events          or {}
    GnomeHunterDB.activeEventId   = GnomeHunterDB.activeEventId   or nil
    GnomeHunterDB.lastEventId     = GnomeHunterDB.lastEventId     or nil  -- último encerrado (p/ exibição quando sem ativo)
    GnomeHunterDB.eventHistoryIds = GnomeHunterDB.eventHistoryIds or {}   -- array FIFO dos últimos EVENT_HISTORY_MAX
    GnomeHunterDB.eventCancelsAt  = GnomeHunterDB.eventCancelsAt  or {}   -- [eventId] = clearedAt (anti-loop)

    -- Kill log local do PRÓPRIO player (rolling buffer).
    -- Entries: { at = <serverUnix>, pts = N, race = "Gnome"|..., victim = "...", lvl = N, eventId = "..." or nil }
    GnomeHunterDB.killLog = GnomeHunterDB.killLog or {}

    -- =================================================================
    -- Estado
    -- =================================================================
    local playerName, playerGUID
    local playerKey  -- nome normalizado do próprio player (lowercase, sem realm)
    local guidRace   = {}   -- GUID -> englishRace
    local guidName   = {}   -- GUID -> nome
    local guidGuild  = {}   -- GUID -> nome da guild
    local guidLevel  = {}   -- GUID -> nível do player
    local guildSet   = {}   -- normKey -> nome original (roster atual)
    local lastAlertAt = {}  -- [key] = GetTime() último alerta

    -- Pega o nome completo da unit incluindo sobrenome (Forever usa "First Last").
    -- Tenta GetUnitName primeiro (retorna o nome com sobrenome no retail),
    -- cai pra UnitName como fallback.
    local function GetFullName(unit)
        unit = unit or "player"
        if GetUnitName then
            local ok, n = pcall(GetUnitName, unit, false)
            if ok and type(n) == "string" and n ~= "" then return n end
        end
        if UnitName then
            local n = UnitName(unit)
            if type(n) == "string" and n ~= "" then return n end
        end
        return nil
    end

    -- Normaliza nome para comparação. No Forever o nome tem sobrenome com hífen
    -- ("First-Last"), então NÃO cortamos no primeiro '-'. Só removemos o sufixo
    -- "-RealmName" se estivermos em multi-realm (ou se a API retornar com realm).
    local function NormKey(name)
        if type(name) ~= "string" or name == "" then return nil end
        local myRealm = GetRealmName and GetRealmName() or ""
        if myRealm ~= "" then
            local escaped = myRealm:gsub("([%%%^%$%(%)%.%[%]%*%+%-%?])", "%%%1")
            name = name:gsub("%-" .. escaped .. "$", "")
        end
        name = name:gsub("^%s+", ""):gsub("%s+$", "")
        return string.lower(name)
    end

    -- Retorna só o primeiro nome (antes do primeiro espaço OU hífen), em lowercase.
    -- Forever usa espaço ("Bollha Tall"); alguns realms usam hífen ("Bollha-Tall").
    local function FirstName(name)
        if type(name) ~= "string" then return nil end
        local first = string.match(name, "^([^%- ]+)")
        return first and string.lower(first) or nil
    end

    -- Match tolerante para bounty: exato, ou se o bounty foi digitado só com o primeiro
    -- nome, bate contra o primeiro nome do alvo. Ex: setar "Bollha" bate em "Bollha Tall".
    local function NameMatchesBounty(victim, bountyName)
        if not victim or not bountyName then return false end
        local vk = NormKey(victim)
        local bk = NormKey(bountyName)
        if not vk or not bk then return false end
        if vk == bk then return true end
        -- Match parcial: bounty é SÓ o primeiro nome (sem sobrenome)
        local vFirst = FirstName(victim)
        local bFirst = FirstName(bountyName)
        if vFirst and bFirst and vFirst == bFirst and bk == bFirst then
            return true
        end
        return false
    end

    -- referências de UI
    local rankFrame
    local bountyPlayerText, bountyGuildText
    local scoreText, rankText, scoreLabel
    local tabWeek, tabAll, tabEvent, footerHint, eventStateBadge, btnCreateEvent, btnCancelEvent
    local rankLines = {}
    local guildCheck, alertCheck, announceCheck
    local btnSetBounty, btnSetGuildBounty, btnReset

    -- Forward declaration (ScheduleRosterRefresh e outras helpers chamam antes da definição)
    local RefreshRankFrame
    local TickEvents, AnnounceEventStart, AnnounceEventEnd

    -- =================================================================
    -- Helpers de valor secreto (Forever)
    -- =================================================================
    local function IsSecret(v)
        return issecretvalue ~= nil and issecretvalue(v) == true
    end
    local function Readable(v)
        if v == nil or IsSecret(v) then return nil end
        return v
    end

    local function Print(msg)
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF8000[GnomeHunter]|r " .. tostring(msg))
    end

    -- =================================================================
    -- Semana (ranking semanal)
    -- =================================================================
    local function ServerNow()
        if GetServerTime then
            local ok, t = pcall(GetServerTime)
            if ok and type(t) == "number" and t > 0 then return t end
        end
        return time()
    end

    local function CurrentWeekId()
        return math.floor((ServerNow() - WEEK_ANCHOR) / WEEK_SECONDS)
    end

    -- Segundos até a próxima virada (terça 12:00 BRT)
    local function SecondsToWeeklyReset()
        local nextReset = WEEK_ANCHOR + (CurrentWeekId() + 1) * WEEK_SECONDS
        return math.max(0, nextReset - ServerNow())
    end

    local function FormatDuration(sec)
        sec = math.floor(sec)
        local d = math.floor(sec / 86400)
        local h = math.floor((sec % 86400) / 3600)
        local m = math.floor((sec % 3600) / 60)
        if d > 0 then return ("%dd %dh"):format(d, h) end
        if h > 0 then return ("%dh %dmin"):format(h, m) end
        return ("%dmin"):format(m)
    end

    -- Zera o ranking semanal se a semana virou. Retorna true se zerou.
    local function EnsureWeek()
        local w = GnomeHunterDB.weekly
        local cur = CurrentWeekId()
        if w.weekId == cur then return false end
        w.weekId = cur
        wipe(w.kills)
        wipe(w.kcount)
        return true
    end

    -- Retorna o evento que deve ser mostrado na view "event":
    -- preferência: ativo > último encerrado > nil
    local function GetDisplayEvent()
        if GnomeHunterDB.activeEventId then
            return GnomeHunterDB.events[GnomeHunterDB.activeEventId]
        end
        if GnomeHunterDB.lastEventId then
            return GnomeHunterDB.events[GnomeHunterDB.lastEventId]
        end
        return nil
    end

    -- Os stores de score têm a mesma forma: { kills = {}, kcount = {} }.
    -- "event" retorna o store do evento ATIVO ou ÚLTIMO; se não houver
    -- nenhum evento, devolve um store vazio e isolado.
    local EMPTY_STORE = { kills = {}, kcount = {} }
    local function ScoreStore(view)
        if view == "week"  then return GnomeHunterDB.weekly end
        if view == "event" then
            local e = GetDisplayEvent()
            if e then return e end
            return EMPTY_STORE
        end
        return GnomeHunterDB
    end
    local SCORE_STORES = { "all", "week" }   -- stores que RegisterKill incrementa automaticamente

    local function ViewLabel(view)
        if view == "week"  then return "Semanal" end
        if view == "event" then return "Evento"  end
        return "Geral"
    end

    -- =================================================================
    -- Eventos (ranking configurável por oficial)
    --
    -- HORA DO SERVIDOR: GetServerTime() retorna unix epoch (UTC).
    -- Internamente usamos UTC. Toda interação com o usuário usa BRT
    -- (UTC-3, sem horário de verão). Mensagens, popups e anúncios
    -- sempre formatam "DD/MM HH:MM BRT".
    -- =================================================================

    -- time(table) do Lua interpreta a tabela como LOCAL (do SO) e devolve epoch UTC.
    -- Essa helper interpreta a tabela como UTC devolvendo epoch UTC, independente do SO.
    local function UtcTableToEpoch(t)
        -- offsetSO = quanto a LOCAL está à frente da UTC
        -- time(date("!*t")) pega a tabela UTC "agora" e interpreta como LOCAL,
        -- então retorna um epoch deslocado pelo offsetSO.
        local offsetSO = time() - time(date("!*t"))
        return time(t) - offsetSO
    end

    -- Converte "YYYY-MM-DD HH:MM" (BRT) para unix epoch UTC. nil se inválido.
    local function ParseBRTDateTime(str)
        if type(str) ~= "string" then return nil end
        local Y, M, D, h, m = string.match(str, "^(%d%d%d%d)%-(%d%d)%-(%d%d)%s+(%d%d):(%d%d)$")
        if not Y then return nil end
        Y, M, D, h, m = tonumber(Y), tonumber(M), tonumber(D), tonumber(h), tonumber(m)
        if not (Y and M and D and h and m) then return nil end
        if M < 1 or M > 12 or D < 1 or D > 31 or h < 0 or h > 23 or m < 0 or m > 59 then
            return nil
        end
        -- Interpreta a tabela como UTC, depois subtrai o BRT_OFFSET (-3h) para
        -- obter o epoch UTC real: 20:00 BRT = 23:00 UTC → epoch + 3h.
        local epochIfUtc = UtcTableToEpoch({ year = Y, month = M, day = D, hour = h, min = m, sec = 0 })
        return epochIfUtc - BRT_OFFSET
    end

    -- Formata unix UTC como "DD/MM HH:MM BRT"
    local function FormatBRT(utc)
        local brt = utc + BRT_OFFSET   -- converte UTC pra "epoch como se fosse BRT"
        -- date("!") trata como UTC, então passar brt devolve os componentes BRT
        local t = date("!*t", brt)
        return ("%02d/%02d %02d:%02d BRT"):format(t.day, t.month, t.hour, t.min)
    end

    -- Garante que o evento ativo ainda está dentro da janela; se expirou, encerra.
    -- Retorna "started" (anúncio start pendente), "ended" (anúncio end pendente), ou nil.
    -- O anúncio real é feito pelo caller (que tem acesso a SafeChat).
    local function PollActiveEvent()
        local now = ServerNow()
        -- Começa um evento futuro que já chegou a hora?
        if not GnomeHunterDB.activeEventId then
            for id, e in pairs(GnomeHunterDB.events) do
                if (not e.finished) and (not e.cancelled)
                   and e.startAt <= now and now < e.endAt then
                    GnomeHunterDB.activeEventId = id
                    if not e.announcedStart then
                        e.announcedStart = true
                        return "started", e
                    end
                    return nil
                end
            end
        else
            local e = GnomeHunterDB.events[GnomeHunterDB.activeEventId]
            if not e or e.cancelled then
                GnomeHunterDB.activeEventId = nil
                return nil
            end
            if now >= e.endAt then
                e.finished = true
                GnomeHunterDB.lastEventId = GnomeHunterDB.activeEventId
                GnomeHunterDB.activeEventId = nil
                if not e.announcedEnd then
                    e.announcedEnd = true
                    return "ended", e
                end
            end
        end
        return nil
    end

    -- true se o evento ID está ativo AGORA (dentro da janela)
    local function IsEventActiveNow(eventId)
        local e = eventId and GnomeHunterDB.events[eventId]
        if not e or e.cancelled or e.finished then return false end
        local now = ServerNow()
        return e.startAt <= now and now < e.endAt
    end

    -- Gera um ID único para novo evento
    local function NewEventId()
        return ("evt_%d_%d"):format(ServerNow(), math.random(0, 9999))
    end

    -- Mantém o histórico limitado aos EVENT_HISTORY_MAX mais recentes
    local function PruneEventHistory()
        local ids = GnomeHunterDB.eventHistoryIds
        while #ids > EVENT_HISTORY_MAX do
            local oldest = table.remove(ids, 1)
            if oldest and oldest ~= GnomeHunterDB.activeEventId and oldest ~= GnomeHunterDB.lastEventId then
                GnomeHunterDB.events[oldest] = nil
            end
        end
    end

    -- Append-only ao kill log local, com prune do tamanho
    local function AppendKillLog(entry)
        local log = GnomeHunterDB.killLog
        log[#log + 1] = entry
        if #log > KILLLOG_MAX then
            -- remove a entrada mais antiga preservando ordem (tira do início)
            table.remove(log, 1)
        end
    end

    local function EnsureEntry(name)
        if not name then return end
        for _, view in ipairs(SCORE_STORES) do
            local s = ScoreStore(view)
            if not s.kills[name]  then s.kills[name]  = 0 end
            if not s.kcount[name] then s.kcount[name] = 0 end
        end
    end

    -- Broadcast para a guild inteira
    local function Broadcast(payload)
        if not IsInGuild() then return end
        if C_ChatInfo and C_ChatInfo.SendAddonMessage then
            pcall(C_ChatInfo.SendAddonMessage, ADDON_PREFIX, payload, "GUILD")
        elseif SendAddonMessage then
            pcall(SendAddonMessage, ADDON_PREFIX, payload, "GUILD")
        end
    end

    -- Escapa | (caractere de escape de cores do WoW) para || - exigido por SendChatMessage
    local function SafeChat(msg, channel)
        if not msg then return end
        msg = tostring(msg):gsub("|", "||")
        SendChatMessage(msg, channel)
    end

    -- Envia addon msg direto para um player (WHISPER) - usado para responder requests
    local function Whisper(payload, target)
        if not target or target == "" then return end
        if C_ChatInfo and C_ChatInfo.SendAddonMessage then
            pcall(C_ChatInfo.SendAddonMessage, ADDON_PREFIX, payload, "WHISPER", target)
        elseif SendAddonMessage then
            pcall(SendAddonMessage, ADDON_PREFIX, payload, "WHISPER", target)
        end
    end

    -- Se target for passado, whisper direto. Senão, broadcast pra guild.
    local function SendMyScore(target)
        if not playerName then return end
        local payload = ("SCORE:%s:%d:%d"):format(
            playerName,
            GnomeHunterDB.kills[playerName]  or 0,
            GnomeHunterDB.kcount[playerName] or 0)
        -- Score semanal vai numa mensagem separada: clientes antigos ignoram
        -- comandos desconhecidos, então isso não quebra quem ainda está na v2.4.
        EnsureWeek()
        local w = GnomeHunterDB.weekly
        local wpayload = ("WSCORE:%s:%d:%d:%d"):format(
            playerName, w.weekId,
            w.kills[playerName]  or 0,
            w.kcount[playerName] or 0)
        if target then
            Whisper(payload, target); Whisper(wpayload, target)
        else
            Broadcast(payload); Broadcast(wpayload)
        end
    end
    local function BroadcastMyScore() SendMyScore(nil) end

    -- Se target for passado, envia só pra ele (WHISPER); senão, broadcast GUILD
    local function SendBounty(target)
        local b = GnomeHunterDB.bounty
        if not (b and b.name) then return end
        local payload = ("BOUNTY:%s:%s:%s:%d"):format(b.name, b.race or "Gnome", b.setBy or "?", b.setAt or 0)
        if target then Whisper(payload, target) else Broadcast(payload) end
    end
    local function BroadcastBounty() SendBounty(nil) end
    local function BroadcastBountyClear()
        Broadcast("BOUNTYCLR:" .. (GnomeHunterDB.bountyClearedAt or time()))
    end

    local function SendGuildBounty(target)
        local b = GnomeHunterDB.guildBounty
        if not (b and b.name) then return end
        local payload = ("GBNTY:%s:%s:%d"):format(b.name, b.setBy or "?", b.setAt or 0)
        if target then Whisper(payload, target) else Broadcast(payload) end
    end
    local function BroadcastGuildBounty() SendGuildBounty(nil) end
    local function BroadcastGuildBountyClear()
        Broadcast("GBCLR:" .. (GnomeHunterDB.guildBountyClearedAt or time()))
    end

    -- Envia metadata de um evento (oficial). Formato:
    -- EVENT:id:startAt:endAt:setBy:setAt:name
    -- Nome é o ÚLTIMO campo porque é o único com conteúdo livre (pode ter ':' ou não).
    local function SendEvent(target, eventId)
        local e = eventId and GnomeHunterDB.events[eventId]
        if not e then return end
        -- Nome sanitizado: troca ':' por ' ' pra não colidir com separador do protocolo
        local safeName = string.gsub(e.name or "", ":", " ")
        local payload = ("EVENT:%s:%d:%d:%s:%d:%s"):format(
            e.id, e.startAt, e.endAt, e.setBy or "?", e.setAt or 0, safeName)
        if target then Whisper(payload, target) else Broadcast(payload) end
    end
    local function BroadcastEvent(eventId) SendEvent(nil, eventId) end
    local function BroadcastEventClear(eventId)
        local at = GnomeHunterDB.eventCancelsAt[eventId] or time()
        Broadcast(("EVENTCLR:%s:%d"):format(eventId, at))
    end

    -- Envia meu score em um evento específico (agregado)
    local function SendEventScore(target, eventId)
        if not playerName then return end
        local e = eventId and GnomeHunterDB.events[eventId]
        if not e then return end
        local pts = (e.kills and e.kills[playerName]) or 0
        local kc  = (e.kcount and e.kcount[playerName]) or 0
        local payload = ("ESCORE:%s:%s:%d:%d"):format(eventId, playerName, pts, kc)
        if target then Whisper(payload, target) else Broadcast(payload) end
    end
    local function BroadcastMyEventScore(eventId) SendEventScore(nil, eventId) end

    -- =================================================================
    -- Guild roster  (GuildRoster() é ASSÍNCRONO: pede ao server, resposta
    -- chega depois via GUILD_ROSTER_UPDATE. Separamos request e iteração.)
    -- =================================================================
    local guildRanks = {}  -- normKey -> rankIndex (0 = GM, 1 = primeiro oficial, etc.)

    -- Pede o roster ao server (async). Não lê nada.
    local function RequestGuildRoster()
        if not IsInGuild() then return end
        if C_GuildInfo and C_GuildInfo.GuildRoster then
            pcall(C_GuildInfo.GuildRoster)
        elseif GuildRoster then
            pcall(GuildRoster)
        end
    end

    -- Lê o roster já populado pelo client. Não dispara request.
    local function RefreshGuildRoster()
        if not IsInGuild() then return end
        wipe(guildSet)
        wipe(guildRanks)
        local n = GetNumGuildMembers and GetNumGuildMembers() or 0
        for i = 1, n do
            local fullName, _, rankIndex = GetGuildRosterInfo(i)
            if type(fullName) == "string" then
                local key = NormKey(fullName)
                if key then
                    guildSet[key] = fullName
                    guildRanks[key] = rankIndex
                end
            end
        end
        -- Agora que temos nomes completos, migra entries curtas do DB
        if n > 0 and MigrateKillsToFullNames then
            MigrateKillsToFullNames()
        end
    end

    -- Pede + agenda releituras em 1s e 4s para pegar a resposta assíncrona
    local function ScheduleRosterRefresh()
        RequestGuildRoster()
        RefreshGuildRoster()   -- tenta imediato caso o client já tenha cache
        if C_Timer and C_Timer.After then
            C_Timer.After(1, function() RefreshGuildRoster(); RefreshRankFrame() end)
            C_Timer.After(4, function() RefreshGuildRoster(); RefreshRankFrame() end)
        end
    end

    local function IsGuildOfficer()
        if not IsInGuild() then return false end
        if CanGuildInvite then
            local ok, can = pcall(CanGuildInvite)
            if ok and can then return true end
        end
        return false
    end

    -- Checa se um nome arbitrário é oficial, consultando o roster
    -- (defensivo: aceita rankIndex 0 ou 1 - GM + primeiro oficial)
    local function IsRosterOfficer(name)
        local key = NormKey(name)
        if not key then return false end
        local rank = guildRanks[key]
        return rank ~= nil and rank <= 1
    end

    -- Dado um nome (possivelmente só "Bollha"), procura no roster pelo
    -- nome completo ("Bollha Tall"). Retorna nil se não achar.
    local function FindFullNameInRoster(name)
        if not name then return nil end
        local key = NormKey(name)
        if not key then return nil end
        -- Match exato primeiro
        if guildSet[key] then return guildSet[key] end
        -- Match por primeiro nome: procura quem tem o mesmo primeiro nome
        for rk, fullName in pairs(guildSet) do
            if FirstName(fullName) == key then
                return fullName
            end
        end
        return nil
    end

    -- Varre o DB de kills procurando entries que têm versão mais completa no roster
    -- e consolida usando MAX (ambas são o MESMO player, não soma).
    local function MigrateKillsToFullNames()
        for _, view in ipairs(SCORE_STORES) do
            local s = ScoreStore(view)
            local moves = {}
            for name in pairs(s.kills) do
                local fullName = FindFullNameInRoster(name)
                if fullName and fullName ~= name then
                    moves[name] = fullName
                end
            end
            for shortName, fullName in pairs(moves) do
                s.kills[fullName]  = math.max(s.kills[fullName]  or 0, s.kills[shortName]  or 0)
                s.kcount[fullName] = math.max(s.kcount[fullName] or 0, s.kcount[shortName] or 0)
                s.kills[shortName]  = nil
                s.kcount[shortName] = nil
            end
        end
    end

    -- =================================================================
    -- Alerta de bounty na área
    -- =================================================================
    local function AlertBountyNearby(label, key)
        if not GnomeHunterDB.opts.bountyAlerts then return end
        key = key or label
        if not key then return end
        key = string.lower(key)
        local now = GetTime()
        if lastAlertAt[key] and (now - lastAlertAt[key]) < ALERT_COOLDOWN then return end
        lastAlertAt[key] = now

        local msg = "BOUNTY NA ÁREA: " .. label
        Print("|cFFFF2020>>>|r |cFFFFD100" .. msg .. "|r |cFFFF2020<<<|r")
        if RaidNotice_AddMessage and RaidWarningFrame then
            local info = (ChatTypeInfo and ChatTypeInfo["RAID_WARNING"]) or { r = 1, g = 0.82, b = 0 }
            pcall(RaidNotice_AddMessage, RaidWarningFrame, msg, info)
        end
        if PlaySound then
            pcall(PlaySound, 8959, "Master")
        end
    end

    -- =================================================================
    -- Scan de unit
    -- =================================================================
    local function ScanUnit(unit)
        if type(unit) ~= "string" then return end
        if not Readable(UnitExists(unit)) then return end
        if not Readable(UnitIsPlayer(unit)) then return end
        local guid = Readable(UnitGUID(unit))
        if type(guid) ~= "string" then return end
        local name = Readable(GetFullName(unit))   -- pega "First Last" no Forever
        if type(name) == "string" and name ~= "" then
            guidName[guid] = name
        end
        local loc, englishRace = UnitRace(unit)
        englishRace = Readable(englishRace) or Readable(loc)
        if englishRace then
            guidRace[guid] = englishRace
        end
        if GetGuildInfo then
            local gname = Readable(GetGuildInfo(unit))
            if type(gname) == "string" and gname ~= "" then
                guidGuild[guid] = gname
            end
        end
        if UnitLevel then
            local lvl = Readable(UnitLevel(unit))
            if type(lvl) == "number" and lvl > 0 then
                guidLevel[guid] = lvl
            end
        end

        -- Alerta de player bounty (match tolerante: "Xulu" bate em "Xulu-Brulesca")
        local b = GnomeHunterDB.bounty
        if b and b.name and type(name) == "string"
           and NameMatchesBounty(name, b.name) then
            AlertBountyNearby(name, "p:" .. name)
        end
        -- Alerta de guild bounty
        local gb = GnomeHunterDB.guildBounty
        if gb and gb.name and guidGuild[guid]
           and string.lower(guidGuild[guid]) == string.lower(gb.name) then
            AlertBountyNearby("<" .. gb.name .. "> " .. (name or ""), "g:" .. guidGuild[guid])
        end
    end

    -- =================================================================
    -- Registro de kill
    -- =================================================================
    local function RegisterKill(victimName, victimRace, victimGuild, victimLevel)
        EnsureEntry(playerName)

        local pb = GnomeHunterDB.bounty
        local gb = GnomeHunterDB.guildBounty
        local isGnome = (victimRace == "Gnome")
        local isPlayerBounty = pb and pb.name and victimName
            and NameMatchesBounty(victimName, pb.name)
        local isGuildBounty = gb and gb.name and victimGuild
            and string.lower(victimGuild) == string.lower(gb.name)

        local pts = 0
        if isGnome then pts = pts + 1 end
        if isPlayerBounty then pts = pts + BOUNTY_BONUS end
        if isGuildBounty then pts = pts + GUILD_BONUS end
        if pts == 0 then return end

        EnsureWeek()
        TickEvents()  -- atualiza activeEventId antes de incrementar
        EnsureEntry(playerName)
        for _, view in ipairs(SCORE_STORES) do
            local s = ScoreStore(view)
            s.kills[playerName]  = (s.kills[playerName]  or 0) + pts
            s.kcount[playerName] = (s.kcount[playerName] or 0) + 1
        end
        local w = GnomeHunterDB.weekly

        -- Se há evento ativo, também incrementa o store dele
        local activeId = GnomeHunterDB.activeEventId
        local activeEvent = activeId and GnomeHunterDB.events[activeId]
        if activeEvent and IsEventActiveNow(activeId) then
            activeEvent.kills[playerName]  = (activeEvent.kills[playerName]  or 0) + pts
            activeEvent.kcount[playerName] = (activeEvent.kcount[playerName] or 0) + 1
        else
            activeId = nil  -- não há evento válido pra esse kill
        end

        -- Append no kill log local (histórico individual)
        AppendKillLog({
            at      = ServerNow(),
            pts     = pts,
            race    = victimRace,
            victim  = victimName,
            lvl     = victimLevel,
            eventId = activeId,
        })

        -- mensagem por prioridade
        local tag
        if isPlayerBounty then
            tag = "|cFFFFD100BOUNTY ABATIDO:|r "
        elseif isGuildBounty and not isGnome then
            tag = ("|cFFFF8000Inimigo de <%s>:|r "):format(gb.name)
        elseif isGuildBounty then
            tag = ("|cFFFF2020Gnomo de <%s>:|r "):format(gb.name)
        else
            tag = "|cFFFF2020Gnomo abatido:|r "
        end
        Print(tag .. (victimName or "?") .. ("|cFF00FF00 (+%d pt)|r"):format(pts)
              .. (" - semana: %d kills / %d pts | geral: %d kills / %d pts"):format(
                  w.kcount[playerName], w.kills[playerName],
                  GnomeHunterDB.kcount[playerName], GnomeHunterDB.kills[playerName]))
        BroadcastMyScore()
        if activeId then
            BroadcastMyEventScore(activeId)
        end

        -- Anuncia o kill no chat da guild
        if GnomeHunterDB.opts.announce and IsInGuild() then
            local me = playerName or "Alguém"
            local target = victimName or "um inimigo"
            local lvlTag = (type(victimLevel) == "number" and victimLevel > 0)
                and (" [lvl %d]"):format(victimLevel) or ""
            local msg
            if isPlayerBounty then
                msg = ("BOUNTY ABATIDO! %s matou %s%s (+%d pts)"):format(me, target, lvlTag, pts)
            elseif isGuildBounty and not isGnome then
                msg = ("%s abateu %s%s de <%s> (+%d pt)"):format(me, target, lvlTag, gb.name, pts)
            elseif isGuildBounty then
                msg = ("%s abateu um gnomo de <%s>: %s%s (+%d pts)"):format(me, gb.name, target, lvlTag, pts)
            else
                msg = ("%s abateu o gnomo %s%s (+%d pt)"):format(me, target, lvlTag, pts)
            end
            SafeChat(msg, "GUILD")
        end
    end

    -- =================================================================
    -- Ranking
    -- =================================================================
    -- view: "week" (semanal) ou "all" (geral)
    local function BuildRankingList(view)
        local store = ScoreStore(view)
        if view == "week" then EnsureWeek() end
        local filter = GnomeHunterDB.opts.guildOnly
        -- Etapa 1: resolve cada entry do DB para o nome mais completo (via roster)
        --          e coalesce duplicatas usando MAX (não soma) - ambas representam o
        --          mesmo player, então pegar o maior valor é o correto.
        local resolved = {}  -- fullName -> { pts, kcount }
        for name, pts in pairs(store.kills) do
            local resolvedName = FindFullNameInRoster(name) or name
            local r = resolved[resolvedName]
            if not r then
                r = { pts = 0, kcount = 0 }
                resolved[resolvedName] = r
            end
            r.pts    = math.max(r.pts,    pts)
            r.kcount = math.max(r.kcount, store.kcount[name] or pts)
        end
        -- Etapa 2: filtra por guild e monta a lista final.
        -- No semanal/evento, quem tem 0 pontos não aparece (exceto você).
        local list = {}
        for name, r in pairs(resolved) do
            local key = NormKey(name)
            local hideZero = (view == "week" or view == "event")
            local hasScore = not hideZero or r.pts > 0 or key == playerKey
            if hasScore and ((not filter) or (key and guildSet[key]) or key == playerKey) then
                table.insert(list, { name = name, count = r.pts, kills = r.kcount })
            end
        end
        -- Ordena por pontos DESC; empate = kills brutos DESC
        table.sort(list, function(a, b)
            if a.count ~= b.count then return a.count > b.count end
            return a.kills > b.kills
        end)
        return list
    end

    local function MyRankAndScore(view)
        local list = BuildRankingList(view)
        local store = ScoreStore(view)
        local myPos = 0
        for i, e in ipairs(list) do
            if e.name == playerName then myPos = i; break end
        end
        return myPos,
               store.kills[playerName]  or 0,
               store.kcount[playerName] or 0
    end

    local function ShowRankingChat(view)
        view = view or "week"
        Print(("=== RANKING DE GNOMICÍDIO - %s ==="):format(string.upper(ViewLabel(view))))
        if view == "week" then
            Print("Zera em " .. FormatDuration(SecondsToWeeklyReset()) .. " (terça 12:00)")
        end
        local list = BuildRankingList(view)
        if #list == 0 then
            Print("Nenhum gnomo abatido ainda. Vai lá!")
            return
        end
        for i, entry in ipairs(list) do
            if i > 20 then break end
            Print(("%d. %s - %d kills (%d pts)"):format(i, entry.name, entry.kills, entry.count))
        end
    end

    -- Envia o ranking no chat da guild (uma linha por entrada, até top 10)
    -- Delay de 0.3s entre mensagens para o server não reordenar
    local function PublishRankingToGuild(top, view)
        view = view or "week"
        if not IsInGuild() then
            Print("Você não está em uma guild.")
            return
        end
        top = math.floor(tonumber(top) or 10)
        if top < 1 then top = 1 end
        if top > MAX_PUBLISH then top = MAX_PUBLISH end
        local list = BuildRankingList(view)
        if #list == 0 then
            Print("Nada para publicar ainda.")
            return
        end

        local pb = GnomeHunterDB.bounty
        local gb = GnomeHunterDB.guildBounty
        local lines = {}
        if view == "week" then
            table.insert(lines, ("=== GnomeHunter - Ranking Semanal (zera em %s) ==="):format(
                FormatDuration(SecondsToWeeklyReset())))
        else
            table.insert(lines, "=== GnomeHunter - Ranking Geral ===")
        end
        if pb and pb.name then
            table.insert(lines, ("Bounty: %s (%s) - vale +%d pts"):format(
                pb.name, pb.race or "?", BOUNTY_BONUS))
        end
        if gb and gb.name then
            table.insert(lines, ("Guild Bounty: <%s> - vale +%d pt por kill"):format(
                gb.name, GUILD_BONUS))
        end
        local n = math.min(top, #list)
        for i = 1, n do
            local e = list[i]
            table.insert(lines, ("%d. %s - %d pts (%d kills)"):format(i, e.name, e.count, e.kills))
        end

        -- Despacha com delay crescente para preservar a ordem
        if C_Timer and C_Timer.After then
            for idx, line in ipairs(lines) do
                C_Timer.After((idx - 1) * 0.35, function()
                    SafeChat(line, "GUILD")
                end)
            end
        else
            for _, line in ipairs(lines) do SafeChat(line, "GUILD") end
        end
        Print(("Ranking %s publicado no chat da guild (top %d)."):format(ViewLabel(view), n))
    end

    -- =================================================================
    -- GUI
    -- =================================================================
    local function MakeTexture(parent, r, g, b, a)
        local tex = parent:CreateTexture(nil, "ARTWORK")
        tex:SetColorTexture(r, g, b, a or 1)
        return tex
    end

    local function RefreshBountyText()
        if not bountyPlayerText then return end
        local pb = GnomeHunterDB.bounty
        if pb and pb.name then
            bountyPlayerText:SetText(("|cFFFFFFFF%s|r |cFFAAAAAA(%s)|r  |cFF00FF00+%d|r"):format(
                pb.name, pb.race or "?", BOUNTY_BONUS))
        else
            bountyPlayerText:SetText("|cFF666666(sem bounty de player)|r")
        end

        local gb = GnomeHunterDB.guildBounty
        if gb and gb.name then
            bountyGuildText:SetText(("|cFFFFFFFF<%s>|r  |cFF00FF00+%d|r"):format(gb.name, GUILD_BONUS))
        else
            bountyGuildText:SetText("|cFF666666(sem bounty de guild)|r")
        end
    end

    RefreshRankFrame = function()
        if not rankFrame or not rankFrame:IsShown() then return end
        RefreshBountyText()
        if guildCheck then guildCheck:SetChecked(GnomeHunterDB.opts.guildOnly) end
        if alertCheck then alertCheck:SetChecked(GnomeHunterDB.opts.bountyAlerts) end
        if announceCheck then announceCheck:SetChecked(GnomeHunterDB.opts.announce) end

        local view = GnomeHunterDB.opts.rankView
        EnsureWeek()
        TickEvents()

        -- abas Semanal / Geral / Evento: a ativa fica com highlight travado
        if tabWeek and tabAll and tabEvent then
            tabWeek:UnlockHighlight(); tabAll:UnlockHighlight(); tabEvent:UnlockHighlight()
            if view == "week" then
                tabWeek:LockHighlight()
            elseif view == "event" then
                tabEvent:LockHighlight()
            else
                tabAll:LockHighlight()
            end
        end

        -- badge do estado do evento
        local displayEvent = GetDisplayEvent()
        if eventStateBadge then
            if not displayEvent then
                eventStateBadge:SetText("")
            elseif displayEvent.cancelled then
                eventStateBadge:SetText("|cFFFF4040CANCELADO|r")
            elseif displayEvent.finished then
                eventStateBadge:SetText("|cFFAAAAAAencerrado|r")
            elseif IsEventActiveNow(displayEvent.id) then
                eventStateBadge:SetText(("|cFF40FF40%s|r"):format(FormatDuration(displayEvent.endAt - ServerNow())))
            else
                eventStateBadge:SetText(("|cFFFFA040em %s|r"):format(FormatDuration(displayEvent.startAt - ServerNow())))
            end
        end

        if footerHint then
            if view == "week" then
                footerHint:SetText(("Semanal zera em |cFFFFD100%s|r (terça 12:00)"):format(
                    FormatDuration(SecondsToWeeklyReset())))
            elseif view == "event" and displayEvent then
                if IsEventActiveNow(displayEvent.id) then
                    footerHint:SetText(("Evento |cFFFFD100'%s'|r - termina em |cFFFFD100%s|r"):format(
                        displayEvent.name, FormatDuration(displayEvent.endAt - ServerNow())))
                elseif displayEvent.finished then
                    footerHint:SetText(("Último evento: |cFFFFD100'%s'|r (encerrado)"):format(displayEvent.name))
                else
                    footerHint:SetText(("Evento |cFFFFD100'%s'|r - inicia em |cFFFFD100%s|r"):format(
                        displayEvent.name, FormatDuration(displayEvent.startAt - ServerNow())))
                end
            elseif view == "event" then
                footerHint:SetText("|cFF888888Nenhum evento registrado|r")
            else
                footerHint:SetText("/gnomo help  -  comandos")
            end
        end

        -- score / rank do player
        local myPos, myScore, myKills = MyRankAndScore(view)
        if scoreLabel then
            local lbl = "Geral:"
            if view == "week"  then lbl = "Semana:" end
            if view == "event" then lbl = "Evento:" end
            scoreLabel:SetText(lbl)
        end
        if scoreText then
            scoreText:SetText(("|cFFFFD100%d|r kills |cFFAAAAAA(%d pts)|r"):format(myKills, myScore))
        end
        if rankText then
            if myPos > 0 then
                rankText:SetText("Rank |cFFFFD100#" .. myPos .. "|r")
            else
                rankText:SetText("|cFF808080Rank -|r")
            end
        end

        -- habilitar botões de bounty/reset só para oficiais
        local officer = IsGuildOfficer()
        if btnSetBounty then
            if officer then btnSetBounty:Enable() else btnSetBounty:Disable() end
        end
        if btnSetGuildBounty then
            if officer then btnSetGuildBounty:Enable() else btnSetGuildBounty:Disable() end
        end
        if btnReset then
            if officer then btnReset:Enable() else btnReset:Disable() end
        end
        if btnCreateEvent then
            if officer then btnCreateEvent:Enable() else btnCreateEvent:Disable() end
        end
        if btnCancelEvent then
            local canCancel = officer and GnomeHunterDB.activeEventId and
                              GnomeHunterDB.events[GnomeHunterDB.activeEventId] and
                              not GnomeHunterDB.events[GnomeHunterDB.activeEventId].finished
            if canCancel then btnCancelEvent:Enable() else btnCancelEvent:Disable() end
        end

        -- lista
        local list = BuildRankingList(view)
        for i = 1, #rankLines do
            local line = rankLines[i]
            local entry = list[i]
            if entry then
                local medal
                if i == 1 then medal = "|cFFFFD100"      -- ouro
                elseif i == 2 then medal = "|cFFC0C0C0"  -- prata
                elseif i == 3 then medal = "|cFFCD7F32"  -- bronze
                else medal = "|cFF888888" end
                local nameColor = (entry.name == playerName) and "|cFFFFFF00" or "|cFFEEEEEE"
                local scoreColor = (entry.name == playerName) and "|cFFFFD100" or "|cFFCCCCCC"
                line.left:SetText(("%s#%d|r  %s%s|r"):format(medal, i, nameColor, entry.name))
                line.right:SetText(("%s%d|r |cFF888888(%d)|r"):format(scoreColor, entry.kills, entry.count))
                if entry.name == playerName then
                    line.bg:Show()
                else
                    line.bg:Hide()
                end
                line:Show()
            else
                line:Hide()
            end
        end
    end

    -- button helper (botão estilo azul do WoW)
    local function MakeButton(parent, label, w, h)
        local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        b:SetSize(w, h)
        b:SetText(label)
        return b
    end

    local function BuildGUI()
        if rankFrame then return end

        rankFrame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
        rankFrame:SetSize(360, 616)
        rankFrame:SetPoint("CENTER")
        rankFrame:SetFrameStrata("DIALOG")
        if rankFrame.SetBackdrop then
            rankFrame:SetBackdrop({
                bgFile   = "Interface\\Buttons\\WHITE8X8",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                tile = false, tileSize = 16, edgeSize = 14,
                insets = { left = 4, right = 4, top = 4, bottom = 4 }
            })
            rankFrame:SetBackdropColor(0.06, 0.04, 0.04, 0.96)
            rankFrame:SetBackdropBorderColor(0.4, 0.1, 0.1, 1)
        end
        rankFrame:SetMovable(true)
        rankFrame:EnableMouse(true)
        rankFrame:RegisterForDrag("LeftButton")
        rankFrame:SetScript("OnDragStart", function(s) s:StartMoving() end)
        rankFrame:SetScript("OnDragStop",  function(s) s:StopMovingOrSizing() end)

        -- HEADER (banner vermelho)
        local header = MakeTexture(rankFrame, 0.35, 0.06, 0.06, 1)
        header:SetPoint("TOPLEFT", 6, -6)
        header:SetPoint("TOPRIGHT", -6, -6)
        header:SetHeight(42)

        local headerShine = MakeTexture(rankFrame, 0.7, 0.15, 0.15, 0.4)
        headerShine:SetPoint("TOPLEFT", header, "TOPLEFT", 0, 0)
        headerShine:SetPoint("TOPRIGHT", header, "TOPRIGHT", 0, 0)
        headerShine:SetHeight(20)

        local titleIcon = rankFrame:CreateTexture(nil, "OVERLAY")
        titleIcon:SetSize(28, 28)
        titleIcon:SetPoint("LEFT", header, "LEFT", 10, 0)
        titleIcon:SetTexture("Interface\\Icons\\INV_Misc_Head_Gnome_01")
        titleIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

        local title = rankFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        title:SetPoint("LEFT", titleIcon, "RIGHT", 8, 0)
        title:SetText("|cFFFFD100CAÇADA AOS GNOMOS|r")

        local versionTag = rankFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        versionTag:SetPoint("BOTTOMLEFT", titleIcon, "BOTTOMRIGHT", 8, -4)
        versionTag:SetText("v" .. VERSION)

        -- Close button
        local close = CreateFrame("Button", nil, rankFrame)
        close:SetSize(22, 22)
        close:SetPoint("TOPRIGHT", -8, -10)
        local closeText = close:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        closeText:SetPoint("CENTER")
        closeText:SetText("|cFFFFAAAAX|r")
        close:SetScript("OnEnter", function(s) closeText:SetText("|cFFFF2020X|r") end)
        close:SetScript("OnLeave", function(s) closeText:SetText("|cFFFFAAAAX|r") end)
        close:SetScript("OnClick", function() rankFrame:Hide() end)

        -- SCORE CARD
        local scoreCard = MakeTexture(rankFrame, 0.10, 0.08, 0.08, 1)
        scoreCard:SetPoint("TOPLEFT", 10, -56)
        scoreCard:SetPoint("TOPRIGHT", -10, -56)
        scoreCard:SetHeight(44)

        scoreLabel = rankFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        scoreLabel:SetPoint("LEFT", scoreCard, "LEFT", 12, 0)
        scoreLabel:SetText("Semana:")

        scoreText = rankFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        scoreText:SetPoint("LEFT", scoreLabel, "RIGHT", 6, 0)
        scoreText:SetText("0 pts")

        rankText = rankFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        rankText:SetPoint("RIGHT", scoreCard, "RIGHT", -12, 0)
        rankText:SetText("Rank -")

        -- BOUNTY CARD
        local bountyCard = MakeTexture(rankFrame, 0.12, 0.06, 0.02, 1)
        bountyCard:SetPoint("TOPLEFT", 10, -104)
        bountyCard:SetPoint("TOPRIGHT", -10, -104)
        bountyCard:SetHeight(80)

        local bountyBar = MakeTexture(rankFrame, 0.55, 0.25, 0.05, 1)
        bountyBar:SetPoint("TOPLEFT", bountyCard, "TOPLEFT", 0, 0)
        bountyBar:SetPoint("TOPRIGHT", bountyCard, "TOPRIGHT", 0, 0)
        bountyBar:SetHeight(18)

        local bountyTitle = rankFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        bountyTitle:SetPoint("LEFT", bountyBar, "LEFT", 8, 0)
        bountyTitle:SetText("|cFFFFFFFFBOUNTY DA SEMANA|r")

        -- linha do player
        local pbIcon = rankFrame:CreateTexture(nil, "OVERLAY")
        pbIcon:SetSize(12, 12)
        pbIcon:SetPoint("TOPLEFT", bountyCard, "TOPLEFT", 12, -24)
        pbIcon:SetTexture("Interface\\Icons\\INV_Misc_GroupNeedMore")
        pbIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

        local pbLabel = rankFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        pbLabel:SetPoint("LEFT", pbIcon, "RIGHT", 6, 0)
        pbLabel:SetText("|cFFFFD100Player:|r")

        bountyPlayerText = rankFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        bountyPlayerText:SetPoint("LEFT", pbLabel, "RIGHT", 4, 0)
        bountyPlayerText:SetPoint("RIGHT", bountyCard, "RIGHT", -10, 0)
        bountyPlayerText:SetJustifyH("LEFT")
        bountyPlayerText:SetText("|cFF666666(sem bounty)|r")

        -- linha da guild
        local gbIcon = rankFrame:CreateTexture(nil, "OVERLAY")
        gbIcon:SetSize(12, 12)
        gbIcon:SetPoint("TOPLEFT", bountyCard, "TOPLEFT", 12, -44)
        gbIcon:SetTexture("Interface\\Icons\\INV_Misc_Tournaments_banner_Scourge")
        gbIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

        local gbLabel = rankFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        gbLabel:SetPoint("LEFT", gbIcon, "RIGHT", 6, 0)
        gbLabel:SetText("|cFFFFD100Guild:|r")

        bountyGuildText = rankFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        bountyGuildText:SetPoint("LEFT", gbLabel, "RIGHT", 4, 0)
        bountyGuildText:SetPoint("RIGHT", bountyCard, "RIGHT", -10, 0)
        bountyGuildText:SetJustifyH("LEFT")
        bountyGuildText:SetText("|cFF666666(sem bounty)|r")

        -- botões de set bounty (só habilitados para oficiais)
        btnSetBounty = MakeButton(rankFrame, "Player", 70, 20)
        btnSetBounty:SetPoint("TOPLEFT", bountyCard, "BOTTOMLEFT", 6, 2)
        btnSetBounty:SetScript("OnClick", function()
            if not IsGuildOfficer() then return end
            StaticPopup_Show("GNOMEHUNTER_SETBOUNTY")
        end)

        btnSetGuildBounty = MakeButton(rankFrame, "Guild", 70, 20)
        btnSetGuildBounty:SetPoint("LEFT", btnSetBounty, "RIGHT", 4, 0)
        btnSetGuildBounty:SetScript("OnClick", function()
            if not IsGuildOfficer() then return end
            StaticPopup_Show("GNOMEHUNTER_SETGUILDBOUNTY")
        end)

        local btnClearBounty = MakeButton(rankFrame, "Clear", 70, 20)
        btnClearBounty:SetPoint("LEFT", btnSetGuildBounty, "RIGHT", 4, 0)
        btnClearBounty:SetScript("OnClick", function()
            if not IsGuildOfficer() then return end
            StaticPopup_Show("GNOMEHUNTER_CLEARBOUNTY")
        end)

        -- OPTIONS
        guildCheck = CreateFrame("CheckButton", nil, rankFrame, "UICheckButtonTemplate")
        guildCheck:SetSize(22, 22)
        guildCheck:SetPoint("TOPLEFT", 12, -220)
        local cl = guildCheck:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        cl:SetPoint("LEFT", guildCheck, "RIGHT", 2, 0)
        cl:SetText("Só membros da guild")
        guildCheck:SetChecked(GnomeHunterDB.opts.guildOnly)
        guildCheck:SetScript("OnClick", function(s)
            GnomeHunterDB.opts.guildOnly = s:GetChecked() and true or false
            ScheduleRosterRefresh()  -- request + releitura com delay
            RefreshRankFrame()
        end)

        alertCheck = CreateFrame("CheckButton", nil, rankFrame, "UICheckButtonTemplate")
        alertCheck:SetSize(22, 22)
        alertCheck:SetPoint("TOPLEFT", 12, -242)
        local al = alertCheck:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        al:SetPoint("LEFT", alertCheck, "RIGHT", 2, 0)
        al:SetText("Avisar quando bounty aparecer")
        alertCheck:SetChecked(GnomeHunterDB.opts.bountyAlerts)
        alertCheck:SetScript("OnClick", function(s)
            GnomeHunterDB.opts.bountyAlerts = s:GetChecked() and true or false
        end)

        announceCheck = CreateFrame("CheckButton", nil, rankFrame, "UICheckButtonTemplate")
        announceCheck:SetSize(22, 22)
        announceCheck:SetPoint("TOPLEFT", 12, -264)
        local anl = announceCheck:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        anl:SetPoint("LEFT", announceCheck, "RIGHT", 2, 0)
        anl:SetText("Anunciar kills na guild")
        announceCheck:SetChecked(GnomeHunterDB.opts.announce)
        announceCheck:SetScript("OnClick", function(s)
            GnomeHunterDB.opts.announce = s:GetChecked() and true or false
        end)

        -- RANKING HEADER
        local rankHeader = MakeTexture(rankFrame, 0.18, 0.03, 0.03, 1)
        rankHeader:SetPoint("TOPLEFT", 10, -294)
        rankHeader:SetPoint("TOPRIGHT", -10, -294)
        rankHeader:SetHeight(20)

        -- abas Semanal / Geral / Evento
        local function SetView(v)
            GnomeHunterDB.opts.rankView = v
            RefreshRankFrame()
        end
        tabWeek = MakeButton(rankFrame, "Semanal", 62, 18)
        tabWeek:SetPoint("LEFT", rankHeader, "LEFT", 4, 0)
        tabWeek:SetScript("OnClick", function() SetView("week") end)

        tabAll = MakeButton(rankFrame, "Geral", 48, 18)
        tabAll:SetPoint("LEFT", tabWeek, "RIGHT", 2, 0)
        tabAll:SetScript("OnClick", function() SetView("all") end)

        tabEvent = MakeButton(rankFrame, "Evento", 56, 18)
        tabEvent:SetPoint("LEFT", tabAll, "RIGHT", 2, 0)
        tabEvent:SetScript("OnClick", function() SetView("event") end)
        tabEvent:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            local e = GetDisplayEvent()
            if e then
                GameTooltip:AddLine(e.name)
                GameTooltip:AddLine(("%s -> %s"):format(FormatBRT(e.startAt), FormatBRT(e.endAt)), 0.8, 0.8, 0.8)
                if e.cancelled then
                    GameTooltip:AddLine("Cancelado", 1, 0.4, 0.4)
                elseif e.finished then
                    GameTooltip:AddLine("Encerrado", 0.7, 0.7, 0.7)
                elseif IsEventActiveNow(e.id) then
                    GameTooltip:AddLine(("Ativo - acaba em %s"):format(FormatDuration(e.endAt - ServerNow())), 0.4, 1, 0.4)
                else
                    GameTooltip:AddLine(("Comeca em %s"):format(FormatDuration(e.startAt - ServerNow())), 1, 0.65, 0.3)
                end
            else
                GameTooltip:AddLine("Nenhum evento registrado")
                GameTooltip:AddLine("Oficiais podem criar via /gnomo event create", 0.7, 0.7, 0.7)
            end
            GameTooltip:Show()
        end)
        tabEvent:SetScript("OnLeave", function() GameTooltip:Hide() end)

        -- badge pequeno à direita das tabs (ATIVO / AGENDADO / ENCERRADO)
        eventStateBadge = rankFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        eventStateBadge:SetPoint("LEFT", tabEvent, "RIGHT", 6, 0)
        eventStateBadge:SetText("")

        local rhRight = rankFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        rhRight:SetPoint("RIGHT", rankHeader, "RIGHT", -10, 0)
        rhRight:SetText("|cFFFFD100KILLS|r |cFF888888(pts)|r")

        -- RANKING LINES
        wipe(rankLines)
        for i = 1, 15 do
            local lineFrame = CreateFrame("Frame", nil, rankFrame)
            lineFrame:SetPoint("TOPLEFT", 10, -318 - (i - 1) * 16)
            lineFrame:SetPoint("TOPRIGHT", -10, -318 - (i - 1) * 16)
            lineFrame:SetHeight(16)

            local bg = MakeTexture(lineFrame, 0.35, 0.25, 0.05, 0.25)
            bg:SetAllPoints()
            bg:Hide()
            lineFrame.bg = bg

            local left = lineFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            left:SetPoint("LEFT", 8, 0)
            left:SetJustifyH("LEFT")
            lineFrame.left = left

            local right = lineFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            right:SetPoint("RIGHT", -8, 0)
            right:SetJustifyH("RIGHT")
            lineFrame.right = right

            rankLines[i] = lineFrame
        end

        -- BOTTOM BUTTONS (4 botões de 78px, gap 4px -> 78*4 + 4*3 = 324, cabe em 340 internos)
        local btnSync = MakeButton(rankFrame, "Sync", 78, 22)
        btnSync:SetPoint("BOTTOMLEFT", 10, 12)
        btnSync:SetScript("OnClick", function()
            if IsInGuild() then
                Broadcast("REQ:" .. (playerName or ""))
                Broadcast("BOUNTYREQ:")
                Broadcast("GBREQ:")
                ScheduleRosterRefresh()
                Print("Sincronizando com a guild...")
            else
                Print("Você não está em uma guild.")
            end
        end)

        local btnPublish = MakeButton(rankFrame, "Publicar", 78, 22)
        btnPublish:SetPoint("LEFT", btnSync, "RIGHT", 4, 0)
        btnPublish:SetScript("OnClick", function()
            StaticPopup_Show("GNOMEHUNTER_PUBLISH", string.lower(ViewLabel(GnomeHunterDB.opts.rankView)))
        end)
        btnPublish:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine("Enviar ranking no chat da guild")
            GameTooltip:AddLine("Top 10 da aba selecionada + bounties ativos", 0.8, 0.8, 0.8)
            GameTooltip:Show()
        end)
        btnPublish:SetScript("OnLeave", function() GameTooltip:Hide() end)

        btnReset = MakeButton(rankFrame, "Reset", 78, 22)
        btnReset:SetPoint("LEFT", btnPublish, "RIGHT", 4, 0)
        btnReset:SetScript("OnClick", function()
            if not IsGuildOfficer() then
                Print("Só oficiais podem resetar o ranking da guild.")
                return
            end
            StaticPopup_Show("GNOMEHUNTER_RESETALL")
        end)
        btnReset:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine("Zerar ranking da GUILD INTEIRA")
            GameTooltip:AddLine("Só oficiais podem acionar", 0.8, 0.8, 0.8)
            GameTooltip:AddLine("Essa ação não pode ser desfeita", 1, 0.3, 0.3)
            GameTooltip:Show()
        end)
        btnReset:SetScript("OnLeave", function() GameTooltip:Hide() end)

        local btnHelp = MakeButton(rankFrame, "Help", 78, 22)
        btnHelp:SetPoint("LEFT", btnReset, "RIGHT", 4, 0)
        btnHelp:SetScript("OnClick", function()
            Print("Digite |cFFFFD100/gnomo help|r no chat para ver todos os comandos.")
        end)

        -- Hint no rodapé
        footerHint = rankFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        footerHint:SetPoint("BOTTOM", 0, 40)
        footerHint:SetText("/gnomo help  -  comandos")

        rankFrame:Hide()
    end

    local function ToggleGUI()
        if not rankFrame then BuildGUI() end
        if rankFrame:IsShown() then
            rankFrame:Hide()
        else
            ScheduleRosterRefresh()  -- pede fresh antes de mostrar
            RefreshRankFrame()
            rankFrame:Show()
        end
    end

    -- =================================================================
    -- Minimap button
    -- =================================================================
    local minimapButton

    -- Raio dinâmico: meio-minimap + offset pra ficar FORA da borda do minimap
    local function GetMinimapRadius()
        local w = Minimap and Minimap:GetWidth() or 140
        return (w / 2) + 10
    end

    local function placeMinimapButton(btn, angle)
        btn:ClearAllPoints()
        local r = GetMinimapRadius()
        btn:SetPoint("CENTER", Minimap, "CENTER",
            math.cos(angle) * r,
            math.sin(angle) * r)
    end

    local function BuildMinimapButton()
        if minimapButton or not Minimap then return end
        local btn = CreateFrame("Button", "GnomeHunterMinimapButton", Minimap)
        btn:SetSize(31, 31)
        btn:SetFrameStrata("MEDIUM")
        btn:SetFrameLevel(8)
        btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        btn:RegisterForDrag("LeftButton")
        btn:SetMovable(true)

        local icon = btn:CreateTexture(nil, "BACKGROUND")
        icon:SetSize(20, 20)
        icon:SetPoint("CENTER")
        icon:SetTexture("Interface\\Icons\\INV_Misc_Head_Gnome_01")
        icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        btn.icon = icon

        local border = btn:CreateTexture(nil, "OVERLAY")
        border:SetSize(53, 53)
        border:SetPoint("TOPLEFT")
        border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

        btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

        btn:SetScript("OnClick", function(_, mouseButton)
            if mouseButton == "RightButton" then
                GnomeHunterDB.opts.bountyAlerts = not GnomeHunterDB.opts.bountyAlerts
                Print("Alertas de bounty: " .. (GnomeHunterDB.opts.bountyAlerts and "ON" or "OFF"))
                RefreshRankFrame()
            else
                ToggleGUI()
            end
        end)

        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:AddLine("|cFFFF8000GnomeHunter|r v"..VERSION)
            EnsureWeek()
            local w = GnomeHunterDB.weekly
            GameTooltip:AddLine(("Semana: |cFFFFD100%d|r kills (|cFFAAAAAA%d pts|r)"):format(
                w.kcount[playerName] or 0, w.kills[playerName] or 0), 1, 1, 1)
            GameTooltip:AddLine(("Geral: |cFFFFD100%d|r kills (|cFFAAAAAA%d pts|r)"):format(
                GnomeHunterDB.kcount[playerName] or 0, GnomeHunterDB.kills[playerName] or 0), 1, 1, 1)
            GameTooltip:AddLine("Semanal zera em " .. FormatDuration(SecondsToWeeklyReset()), 0.6, 0.6, 0.6)
            local pb = GnomeHunterDB.bounty
            if pb and pb.name then
                GameTooltip:AddLine(("Bounty: %s (+%d pts)"):format(pb.name, BOUNTY_BONUS), 1, 0.82, 0)
            end
            local gb = GnomeHunterDB.guildBounty
            if gb and gb.name then
                GameTooltip:AddLine(("Guild bounty: <%s> (+%d pt)"):format(gb.name, GUILD_BONUS), 1, 0.82, 0)
            end
            if not (pb and pb.name) and not (gb and gb.name) then
                GameTooltip:AddLine("Sem bounty ativo", 0.6, 0.6, 0.6)
            end
            GameTooltip:AddLine(("Alertas: %s"):format(GnomeHunterDB.opts.bountyAlerts and "ON" or "OFF"), 0.8, 0.8, 0.8)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Clique esq: abre ranking", 0.7, 0.7, 0.7)
            GameTooltip:AddLine("Clique dir: liga/desliga alertas", 0.7, 0.7, 0.7)
            GameTooltip:AddLine("Arrastar: mover o botão", 0.5, 0.5, 0.5)
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

        btn:SetScript("OnDragStart", function(self)
            self:SetScript("OnUpdate", function()
                local mx, my = GetCursorPosition()
                -- GetCenter() do Minimap vem no espaço de coordenadas DELE,
                -- então o cursor precisa ser convertido pela escala efetiva do Minimap
                local scale = Minimap:GetEffectiveScale() or 1
                mx, my = mx / scale, my / scale
                local cx, cy = Minimap:GetCenter()
                if cx and cy then
                    local angle = math.atan2(my - cy, mx - cx)
                    GnomeHunterDB.minimap.angle = angle
                    placeMinimapButton(self, angle)  -- usa GetMinimapRadius()
                end
            end)
        end)
        btn:SetScript("OnDragStop", function(self)
            self:SetScript("OnUpdate", nil)
        end)

        placeMinimapButton(btn, GnomeHunterDB.minimap.angle or 0.45)
        btn:SetShown(not GnomeHunterDB.minimap.hide)
        minimapButton = btn
    end

    local function ToggleMinimapButton()
        GnomeHunterDB.minimap.hide = not GnomeHunterDB.minimap.hide
        if minimapButton then
            minimapButton:SetShown(not GnomeHunterDB.minimap.hide)
        end
        Print("Botão do minimap: " .. (GnomeHunterDB.minimap.hide and "oculto" or "visível"))
    end

    -- =================================================================
    -- Bounty (set/clear) com timestamp para evitar wipe no relogin
    -- =================================================================
    local function SetBounty(name, race, setBy)
        if not name or name == "" then return end
        race = race or "Gnome"
        GnomeHunterDB.bounty = {
            name  = name,
            race  = race,
            setBy = setBy or playerName or "?",
            setAt = time(),
        }
        wipe(lastAlertAt)
        Print(("|cFFFFD100Bounty definido:|r %s (%s) +%d pts  [por %s]"):format(
            name, race, BOUNTY_BONUS, GnomeHunterDB.bounty.setBy))
        RefreshRankFrame()
    end

    local function ClearBounty()
        GnomeHunterDB.bounty = nil
        GnomeHunterDB.bountyClearedAt = time()
        wipe(lastAlertAt)
        Print("|cFFFFD100Bounty de player removido.|r")
        RefreshRankFrame()
    end

    local function SetGuildBounty(gname, setBy)
        if not gname or gname == "" then return end
        GnomeHunterDB.guildBounty = {
            name  = gname,
            setBy = setBy or playerName or "?",
            setAt = time(),
        }
        wipe(lastAlertAt)
        Print(("|cFFFFD100Guild bounty definido:|r <%s> +%d pt  [por %s]"):format(
            gname, GUILD_BONUS, GnomeHunterDB.guildBounty.setBy))
        RefreshRankFrame()
    end

    local function ClearGuildBounty()
        GnomeHunterDB.guildBounty = nil
        GnomeHunterDB.guildBountyClearedAt = time()
        wipe(lastAlertAt)
        Print("|cFFFFD100Guild bounty removido.|r")
        RefreshRankFrame()
    end

    -- =================================================================
    -- Eventos: cria, cancela e anuncia
    -- =================================================================
    AnnounceEventStart = function(e)
        if not IsInGuild() then return end
        local msg = (">> Evento '%s' comecou! Vale ate %s (contagem exclusiva deste evento no ranking)"):format(
            e.name, FormatBRT(e.endAt))
        SafeChat(msg, "GUILD")
    end

    AnnounceEventEnd = function(e)
        if not IsInGuild() then return end
        -- Procura o vencedor nos agregados do evento
        local topName, topPts, topKcnt = nil, -1, 0
        for name, pts in pairs(e.kills or {}) do
            if pts > topPts then
                topName, topPts, topKcnt = name, pts, (e.kcount and e.kcount[name]) or 0
            end
        end
        local msg
        if topName and topPts > 0 then
            msg = (">> Evento '%s' encerrado! Campeao: %s com %d kills (%d pts)"):format(
                e.name, topName, topKcnt, topPts)
        else
            msg = (">> Evento '%s' encerrado sem kills registrados."):format(e.name)
        end
        SafeChat(msg, "GUILD")
    end  -- AnnounceEventEnd

    -- Verifica mudança de estado do evento e dispara anúncio quando necessário.
    -- Chamada periodicamente pelo ticker + no login + nos handlers de rede.
    TickEvents = function()
        local change, e = PollActiveEvent()
        if change == "started" then
            AnnounceEventStart(e)
        elseif change == "ended" then
            AnnounceEventEnd(e)
        end
    end

    -- Cria evento (chamador já validou que é oficial). startAt é unix UTC.
    -- durationH é em horas (número positivo). name já veio truncado e validado.
    -- Retorna o eventId ou nil + razão.
    local function CreateEvent(name, startAt, durationH, setBy)
        if type(name) ~= "string" or name == "" then
            return nil, "Nome obrigatório."
        end
        if #name > EVENT_NAME_MAX_LEN then
            name = string.sub(name, 1, EVENT_NAME_MAX_LEN)
        end
        if type(startAt) ~= "number" or type(durationH) ~= "number" then
            return nil, "Datahora ou duração inválidas."
        end
        if durationH <= 0 or durationH > EVENT_MAX_DURATION_H then
            return nil, ("Duração deve ser entre 0 e %d horas."):format(EVENT_MAX_DURATION_H)
        end
        local endAt = startAt + math.floor(durationH * 3600)
        if endAt <= ServerNow() then
            return nil, "Evento já estaria encerrado (verifique a data/hora)."
        end
        local id = NewEventId()
        local e = {
            id      = id,
            name    = name,
            startAt = startAt,
            endAt   = endAt,
            setBy   = setBy or playerName or "?",
            setAt   = ServerNow(),
            kills   = {},
            kcount  = {},
        }
        GnomeHunterDB.events[id] = e
        table.insert(GnomeHunterDB.eventHistoryIds, id)
        PruneEventHistory()
        -- Se um outro evento ainda estava marcado como ativo, cancela — só 1 por vez.
        if GnomeHunterDB.activeEventId and GnomeHunterDB.activeEventId ~= id then
            local old = GnomeHunterDB.events[GnomeHunterDB.activeEventId]
            if old and not old.finished then
                old.cancelled = true
                GnomeHunterDB.eventCancelsAt[old.id] = ServerNow()
            end
            GnomeHunterDB.activeEventId = nil
        end
        Print(("|cFFFFD100Evento criado:|r '%s' (%s -> %s)"):format(
            e.name, FormatBRT(e.startAt), FormatBRT(e.endAt)))
        TickEvents()  -- em caso de start imediato
        return id
    end

    local function CancelEvent(id)
        local e = id and GnomeHunterDB.events[id]
        if not e then return false end
        e.cancelled = true
        GnomeHunterDB.eventCancelsAt[id] = ServerNow()
        if GnomeHunterDB.activeEventId == id then
            GnomeHunterDB.activeEventId = nil
            GnomeHunterDB.lastEventId = id
        end
        Print(("|cFFFFD100Evento '%s' cancelado.|r"):format(e.name or id))
        return true
    end

    -- =================================================================
    -- Static popups (dialogs seguros do Blizzard)
    -- No retail moderno (Forever) a propriedade é EditBox; na vanilla era editBox.
    -- =================================================================
    local function PopupEditBox(popup)
        if not popup then return nil end
        return popup.editBox
            or popup.EditBox
            or (popup.GetEditBox and popup:GetEditBox())
            or (popup:GetName() and _G[popup:GetName() .. "EditBox"])
    end
    local function PopupPrimaryButton(popup)
        if not popup then return nil end
        if popup.button1 then return popup.button1 end
        if popup.Buttons and popup.Buttons[1] then return popup.Buttons[1] end
        if popup.GetButton then
            local ok, btn = pcall(popup.GetButton, popup, 1)
            if ok and btn then return btn end
        end
        if popup:GetName() then return _G[popup:GetName() .. "Button1"] end
        return nil
    end

    StaticPopupDialogs["GNOMEHUNTER_SETBOUNTY"] = {
        text = "Nome do bounty (jogador da Aliança):",
        button1 = "Set", button2 = CANCEL,
        hasEditBox = 1, maxLetters = 32,
        OnAccept = function(self)
            local eb = PopupEditBox(self)
            local n = eb and eb:GetText()
            if n and n ~= "" then
                SetBounty(n, "Gnome", playerName)
                BroadcastBounty()
            end
        end,
        EditBoxOnEnterPressed = function(self)
            local btn = PopupPrimaryButton(self:GetParent())
            if btn then btn:Click() end
        end,
        EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
        OnShow = function(self)
            local eb = PopupEditBox(self)
            if eb then eb:SetFocus() end
        end,
        timeout = 0, whileDead = 1, hideOnEscape = 1, preferredIndex = 3,
    }

    StaticPopupDialogs["GNOMEHUNTER_SETGUILDBOUNTY"] = {
        text = "Nome da guild inimiga:",
        button1 = "Set", button2 = CANCEL,
        hasEditBox = 1, maxLetters = 40,
        OnAccept = function(self)
            local eb = PopupEditBox(self)
            local n = eb and eb:GetText()
            if n and n ~= "" then
                SetGuildBounty(n, playerName)
                BroadcastGuildBounty()
            end
        end,
        EditBoxOnEnterPressed = function(self)
            local btn = PopupPrimaryButton(self:GetParent())
            if btn then btn:Click() end
        end,
        EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
        OnShow = function(self)
            local eb = PopupEditBox(self)
            if eb then eb:SetFocus() end
        end,
        timeout = 0, whileDead = 1, hideOnEscape = 1, preferredIndex = 3,
    }

    StaticPopupDialogs["GNOMEHUNTER_CLEARBOUNTY"] = {
        text = "Limpar bounties ativos?",
        button1 = "Limpar", button2 = CANCEL,
        OnAccept = function()
            if GnomeHunterDB.bounty then
                ClearBounty()
                BroadcastBountyClear()
            end
            if GnomeHunterDB.guildBounty then
                ClearGuildBounty()
                BroadcastGuildBountyClear()
            end
        end,
        timeout = 0, whileDead = 1, hideOnEscape = 1, preferredIndex = 3,
    }

    StaticPopupDialogs["GNOMEHUNTER_RESETME"] = {
        text = "Zerar seu próprio score (semanal e geral)?",
        button1 = "Sim", button2 = CANCEL,
        OnAccept = function()
            if playerName then
                for _, view in ipairs(SCORE_STORES) do
                    ScoreStore(view).kills[playerName]  = 0
                    ScoreStore(view).kcount[playerName] = 0
                end
                BroadcastMyScore()
                Print("Sua contagem foi zerada.")
                RefreshRankFrame()
            end
        end,
        timeout = 0, whileDead = 1, hideOnEscape = 1, preferredIndex = 3,
    }

    StaticPopupDialogs["GNOMEHUNTER_RESETALL"] = {
        text = "|cFFFF2020ATENÇÃO:|r zerar o score de TODA a guild?\nEssa ação é irreversível.",
        button1 = "Zerar tudo", button2 = CANCEL,
        OnAccept = function()
            if not IsGuildOfficer() then return end
            local at = time()
            -- zera localmente (geral + semanal)
            GnomeHunterDB.kills  = {}
            GnomeHunterDB.kcount = {}
            wipe(GnomeHunterDB.weekly.kills)
            wipe(GnomeHunterDB.weekly.kcount)
            if playerName then EnsureEntry(playerName) end
            GnomeHunterDB.resetAt = at
            Print("|cFFFFD100Ranking zerado para toda a guild.|r")
            -- broadcast para a guild
            Broadcast("RESETALL:" .. at)
            RefreshRankFrame()
        end,
        timeout = 0, whileDead = 1, hideOnEscape = 1, preferredIndex = 3,
    }

    StaticPopupDialogs["GNOMEHUNTER_PUBLISH"] = {
        text = "Publicar ranking %s no chat da guild? (top 10 + bounties ativos)",
        button1 = "Publicar", button2 = CANCEL,
        OnAccept = function() PublishRankingToGuild(10, GnomeHunterDB.opts.rankView) end,
        timeout = 0, whileDead = 1, hideOnEscape = 1, preferredIndex = 3,
    }

    -- =================================================================
    -- Slash handler
    -- =================================================================
    local function SlashHandler(msg)
        msg = msg or ""
        local lower = string.lower(msg)
        local cmd, rest = string.match(lower, "^(%S+)%s*(.*)$")

        if lower == "" or cmd == "semana" or cmd == "semanal" or cmd == "week" then
            ShowRankingChat("week")
        elseif cmd == "geral" or cmd == "all" or cmd == "total" then
            ShowRankingChat("all")
        elseif cmd == "ui" or cmd == "show" or cmd == "janela" then
            ToggleGUI()
        elseif cmd == "sync" then
            if IsInGuild() then
                Broadcast("REQ:" .. (playerName or ""))
                Broadcast("BOUNTYREQ:")
                Broadcast("GBREQ:")
                ScheduleRosterRefresh()
                Print("Sincronizando com a guild...")
            else
                Print("Você não está em uma guild.")
            end
        elseif cmd == "guildonly" then
            GnomeHunterDB.opts.guildOnly = not GnomeHunterDB.opts.guildOnly
            ScheduleRosterRefresh()
            Print("Filtro 'só guild': " .. (GnomeHunterDB.opts.guildOnly and "ON" or "OFF"))
            RefreshRankFrame()
        elseif cmd == "minimap" then
            ToggleMinimapButton()
        elseif cmd == "alerts" or cmd == "alertas" then
            GnomeHunterDB.opts.bountyAlerts = not GnomeHunterDB.opts.bountyAlerts
            Print("Alertas de bounty: " .. (GnomeHunterDB.opts.bountyAlerts and "ON" or "OFF"))
            RefreshRankFrame()
        elseif cmd == "announce" or cmd == "anunciar" then
            GnomeHunterDB.opts.announce = not GnomeHunterDB.opts.announce
            Print("Anunciar kills na guild: " .. (GnomeHunterDB.opts.announce and "ON" or "OFF"))
            RefreshRankFrame()
        elseif cmd == "deathannounce" or cmd == "anunciarmorte" then
            GnomeHunterDB.opts.announceDeath = not GnomeHunterDB.opts.announceDeath
            Print("Anunciar morte em open-world PvP: " .. (GnomeHunterDB.opts.announceDeath and "ON" or "OFF"))
        elseif cmd == "testalert" then
            wipe(lastAlertAt)
            AlertBountyNearby(GnomeHunterDB.bounty and GnomeHunterDB.bounty.name or "TESTE", "test")
        elseif cmd == "bounty" then
            local orig = string.match(msg, "^%S+%s+(.*)$") or ""
            if orig == "" or string.lower(orig) == "clear" or string.lower(orig) == "limpar" then
                if IsGuildOfficer() then
                    ClearBounty()
                    BroadcastBountyClear()
                else
                    Print("Só oficiais da guild podem mexer no bounty.")
                end
            else
                if not IsGuildOfficer() then
                    Print("Só oficiais da guild podem mexer no bounty.")
                    return
                end
                -- Nome inteiro é o nome do alvo (suporta "Bollha Tall").
                -- Raça pode ser informada entre colchetes: /gnomo bounty Bollha Tall [Human]
                local bname, brace = orig, "Gnome"
                local nameWithoutRace, racePart = string.match(orig, "^(.+)%s+%[(.+)%]%s*$")
                if nameWithoutRace and racePart then
                    bname = nameWithoutRace:gsub("^%s+", ""):gsub("%s+$", "")
                    brace = racePart:gsub("^%s+", ""):gsub("%s+$", "")
                end
                SetBounty(bname, brace, playerName)
                BroadcastBounty()
            end
        elseif cmd == "guildbounty" or cmd == "gbounty" or cmd == "gb" then
            local orig = string.match(msg, "^%S+%s+(.*)$") or ""
            if orig == "" or string.lower(orig) == "clear" or string.lower(orig) == "limpar" then
                if IsGuildOfficer() then
                    ClearGuildBounty()
                    BroadcastGuildBountyClear()
                else
                    Print("Só oficiais da guild podem mexer no guild bounty.")
                end
            else
                if not IsGuildOfficer() then
                    Print("Só oficiais da guild podem mexer no guild bounty.")
                    return
                end
                SetGuildBounty(orig, playerName)
                BroadcastGuildBounty()
            end
        elseif cmd == "event" or cmd == "evento" then
            -- Parse pela string original (preserva case e o nome entre aspas)
            local origRest = string.match(msg, "^%S+%s+(.*)$") or ""
            local sub = string.match(string.lower(origRest), "^(%S+)")
            if not sub or sub == "" or sub == "help" or sub == "?" then
                Print("|cFFFFD100Comandos de evento:|r")
                Print("  /gnomo event create \"Nome do evento\" YYYY-MM-DD HH:MM <horas>")
                Print("     ex: /gnomo event create \"Raid em SG\" 2026-11-28 20:00 2")
                Print("     (data/hora no fuso de BRASÍLIA - BRT, UTC-3)")
                Print("  /gnomo event cancel     - cancela o evento ativo (oficial)")
                Print("  /gnomo event info       - mostra o evento ativo/último")
            elseif sub == "create" or sub == "criar" or sub == "novo" then
                if not IsGuildOfficer() then
                    Print("Só oficiais podem criar eventos.")
                    return
                end
                -- origRest sem o "create "
                local args = string.match(origRest, "^%S+%s+(.*)$") or ""
                -- Extrai nome entre aspas: "..." ou '...'
                local name, after = string.match(args, "^%s*\"(.-)\"%s*(.*)$")
                if not name then
                    name, after = string.match(args, "^%s*'(.-)'%s*(.*)$")
                end
                if not name then
                    Print("|cFFFF8080Uso:|r /gnomo event create \"Nome\" YYYY-MM-DD HH:MM <horas>")
                    return
                end
                local dstr, tstr, durStr = string.match(after, "^(%d%d%d%d%-%d%d%-%d%d)%s+(%d%d:%d%d)%s+(%S+)$")
                if not dstr then
                    Print("|cFFFF8080Uso:|r /gnomo event create \"Nome\" YYYY-MM-DD HH:MM <horas>")
                    Print("     ex: /gnomo event create \"Raid em SG\" 2026-11-28 20:00 2")
                    return
                end
                local startAt = ParseBRTDateTime(dstr .. " " .. tstr)
                local dur = tonumber(durStr)
                if not startAt then
                    Print("|cFFFF8080Data/hora inválida. Formato: YYYY-MM-DD HH:MM (hora de Brasília).|r")
                    return
                end
                if not dur or dur <= 0 then
                    Print("|cFFFF8080Duração deve ser um número positivo de horas.|r")
                    return
                end
                local id, err = CreateEvent(name, startAt, dur, playerName)
                if not id then
                    Print("|cFFFF8080" .. (err or "Erro ao criar evento") .. "|r")
                    return
                end
                BroadcastEvent(id)
            elseif sub == "cancel" or sub == "cancelar" then
                if not IsGuildOfficer() then
                    Print("Só oficiais podem cancelar eventos.")
                    return
                end
                local id = GnomeHunterDB.activeEventId or GnomeHunterDB.lastEventId
                if not id or not GnomeHunterDB.events[id] or GnomeHunterDB.events[id].finished then
                    Print("Não há evento ativo para cancelar.")
                    return
                end
                if CancelEvent(id) then
                    BroadcastEventClear(id)
                end
            elseif sub == "info" or sub == "status" then
                local id = GnomeHunterDB.activeEventId or GnomeHunterDB.lastEventId
                local e = id and GnomeHunterDB.events[id]
                if not e then
                    Print("Nenhum evento registrado ainda.")
                    return
                end
                local state
                if e.cancelled then state = "|cFFFF4040CANCELADO|r"
                elseif e.finished then state = "|cFFAAAAAAencerrado|r"
                elseif IsEventActiveNow(id) then state = "|cFF40FF40ATIVO|r"
                else state = "|cFFFFAA40aguardando início|r" end
                Print(("|cFFFFD100Evento:|r '%s' (%s)"):format(e.name, state))
                Print(("  início: %s | fim: %s"):format(FormatBRT(e.startAt), FormatBRT(e.endAt)))
                Print(("  criado por: %s"):format(e.setBy or "?"))
                local nParticipants = 0
                for _ in pairs(e.kills or {}) do nParticipants = nParticipants + 1 end
                Print(("  participantes com kills: %d"):format(nParticipants))
            else
                Print("Subcomando desconhecido. Use: /gnomo event help")
            end
        elseif cmd == "publish" or cmd == "publicar" or cmd == "share" then
            -- /gnomo publish [N] [semana|geral]  (ordem livre; padrão: 10, semanal)
            local n, view = 10, "week"
            for word in string.gmatch(rest or "", "%S+") do
                if word == "geral" or word == "all" or word == "total" then
                    view = "all"
                elseif word == "semana" or word == "semanal" or word == "week" then
                    view = "week"
                else
                    n = tonumber(word)
                    if not n or n < 1 or n ~= math.floor(n) then
                        Print(("Uso: /gnomo publish [N] [semana|geral]  (N entre 1 e %d)"):format(MAX_PUBLISH))
                        return
                    end
                end
            end
            if n > MAX_PUBLISH then
                Print(("Limitado a top %d para não floodar o /g."):format(MAX_PUBLISH))
            end
            PublishRankingToGuild(n, view)
        elseif cmd == "resetme" then
            if playerName then
                for _, view in ipairs(SCORE_STORES) do
                    ScoreStore(view).kills[playerName]  = 0
                    ScoreStore(view).kcount[playerName] = 0
                end
                BroadcastMyScore()
                Print("Sua contagem foi zerada.")
                RefreshRankFrame()
            end
        elseif cmd == "resetall" then
            GnomeHunterDB.kills  = {}
            GnomeHunterDB.kcount = {}
            wipe(GnomeHunterDB.weekly.kills)
            wipe(GnomeHunterDB.weekly.kcount)
            if playerName then EnsureEntry(playerName) end
            Print("Base local zerada. Use /gnomo sync para pegar os valores da guild.")
            RefreshRankFrame()
        elseif cmd == "build" then
            local v, b, _, i = GetBuildInfo()
            Print("Client: "..tostring(v).." build "..tostring(b).." interface "..tostring(i))
        elseif cmd == "test" then
            local n, r, g, lvl
            if UnitExists("target") and UnitIsPlayer("target") then
                n = GetFullName("target")
                local _, englishRace = UnitRace("target")
                r = Readable(englishRace) or "Gnome"
                g = GetGuildInfo and Readable(GetGuildInfo("target")) or nil
                lvl = UnitLevel and Readable(UnitLevel("target")) or nil
                ScanUnit("target")
            else
                n, r, lvl = "TESTE", "Gnome", 60
            end
            RegisterKill(n, r, g, lvl)
            RefreshRankFrame()
        elseif cmd == "status" then
            local tally = 0
            for _ in pairs(guidRace) do tally = tally + 1 end
            local g = 0
            for _ in pairs(guildSet) do g = g + 1 end
            Print("Players em cache: "..tally.." | Membros da guild conhecidos: "..g.." | Meu GUID: "..tostring(playerGUID))
            Print("Oficial? "..(IsGuildOfficer() and "sim" or "não"))
            local pb = GnomeHunterDB.bounty
            local gb = GnomeHunterDB.guildBounty
            Print("Player bounty: " .. (pb and (pb.name.." (setAt="..tostring(pb.setAt)..")") or "nenhum"))
            Print("Guild bounty: " .. (gb and ("<"..gb.name.."> (setAt="..tostring(gb.setAt)..")") or "nenhum"))
            EnsureWeek()
            Print(("Semana: id=%d | zera em %s | hora do servidor=%d"):format(
                GnomeHunterDB.weekly.weekId, FormatDuration(SecondsToWeeklyReset()), ServerNow()))
        elseif cmd == "migrate" then
            ScheduleRosterRefresh()
            local before = 0
            for _ in pairs(GnomeHunterDB.kills) do before = before + 1 end
            MigrateKillsToFullNames()
            local after = 0
            for _ in pairs(GnomeHunterDB.kills) do after = after + 1 end
            Print(("Migração: %d entries antes -> %d depois (%d duplicatas mescladas)"):format(
                before, after, before - after))
            RefreshRankFrame()
        elseif cmd == "me" then
            Print("=== Debug: nome capturado ===")
            Print("playerName (addon): '" .. tostring(playerName) .. "'")
            Print("UnitName('player'): '" .. tostring(UnitName("player")) .. "'")
            if GetUnitName then
                Print("GetUnitName false: '" .. tostring(GetUnitName("player", false)) .. "'")
                Print("GetUnitName true:  '" .. tostring(GetUnitName("player", true)) .. "'")
            end
            if UnitFullName then
                local n, r = UnitFullName("player")
                Print(("UnitFullName: name='%s' realm='%s'"):format(tostring(n), tostring(r)))
            end
            Print("playerKey (normalizado): '" .. tostring(playerKey) .. "'")
            Print("Realm: '" .. tostring(GetRealmName and GetRealmName() or "?") .. "'")
        elseif cmd == "roster" then
            ScheduleRosterRefresh()
            RefreshGuildRoster()
            Print("=== Guild roster conhecido ===")
            Print("Meu nome: "..tostring(playerName).." | normalizado: "..tostring(playerKey))
            local count = 0
            for key, orig in pairs(guildSet) do
                local rank = guildRanks[key]
                local marker = (rank and rank <= 1) and " |cFFFFD100[OFICIAL]|r" or ""
                Print(("  %s (key=%s, rank=%s)%s"):format(orig, key, tostring(rank), marker))
                count = count + 1
                if count >= 30 then Print("  ... (truncado)"); break end
            end
            if count == 0 then Print("  (vazio - guild roster não carregado ou guild offline)") end
        elseif cmd == "help" or cmd == "?" then
            Print("Comandos:")
            Print("  /gnomo                  - ranking SEMANAL no chat (zera terça 12:00)")
            Print("  /gnomo geral            - ranking GERAL no chat")
            Print("  /gnomo ui               - abre/fecha janela")
            Print("  /gnomo sync             - pede valores da guild")
            Print("  /gnomo guildonly        - alterna filtro 'só membros da guild'")
            Print("  /gnomo alerts           - liga/desliga alerta de bounty próximo")
            Print("  /gnomo announce         - liga/desliga anúncio automático de kills na guild")
            Print("  /gnomo deathannounce    - liga/desliga anúncio de MORTE em open-world PvP (default OFF)")
            Print("  /gnomo minimap          - mostra/oculta botão no minimap")
            Print("  /gnomo testalert        - dispara um alerta de teste")
            Print("  /gnomo bounty <nome completo> [raça entre colchetes]  - define player bounty (oficial)")
            Print("     ex: /gnomo bounty Bollha Tall      ou      /gnomo bounty Bollha Tall [Human]")
            Print("  /gnomo bounty clear     - remove player bounty (oficial)")
            Print("  /gnomo guildbounty <nome da guild>  - define guild bounty (oficial)")
            Print("  /gnomo guildbounty clear  - remove guild bounty (oficial)")
            Print("  /gnomo event create \"Nome\" YYYY-MM-DD HH:MM <horas> - cria evento em horário BRT (oficial)")
            Print("  /gnomo event cancel     - cancela evento ativo (oficial)")
            Print("  /gnomo event info       - mostra status do evento atual")
            Print("  /gnomo publish [N] [geral] - envia top N (padrão 10, semanal) no chat da guild")
            Print("  /gnomo resetme          - zera sua contagem")
            Print("  /gnomo resetall         - zera base local")
            Print("  /gnomo test             - simula kill no target atual")
            Print("  /gnomo status           - debug")
            Print("  /gnomo build            - versão do cliente")
        else
            Print("Comando desconhecido. /gnomo help")
        end
    end

    -- =================================================================
    -- Identificação do killer (sem combat log no Forever)
    -- Considera o target e todas as nameplates visíveis. Só retorna um unit
    -- se houver EXATAMENTE UM player hostil vivo mirando em você e nenhum
    -- NPC hostil mirando em você (senão a morte provavelmente foi PvE ou
    -- é ambígua - melhor não anunciar do que culpar a pessoa errada).
    -- =================================================================
    local function FindLikelyKiller()
        local seen = {}          -- GUID -> true (target e nameplate podem ser o mesmo)
        local playerUnit, playerCount = nil, 0
        local npcOnMe = false

        local function consider(unit)
            if not Readable(UnitExists(unit)) then return end
            local guid = Readable(UnitGUID(unit))
            if type(guid) ~= "string" or seen[guid] then return end
            seen[guid] = true
            if not Readable(UnitCanAttack("player", unit)) then return end
            if Readable(UnitIsDead(unit)) then return end
            if not Readable(UnitIsUnit(unit .. "target", "player")) then return end
            if Readable(UnitIsPlayer(unit)) then
                playerCount = playerCount + 1
                playerUnit = unit
            else
                npcOnMe = true
            end
        end

        consider("target")
        for i = 1, 40 do
            consider("nameplate" .. i)
        end

        if npcOnMe or playerCount ~= 1 then return nil end
        return playerUnit
    end

    -- =================================================================
    -- Handler principal
    -- =================================================================
    local function MainHandler(frame, event, arg1, arg2, arg3, arg4)
        if event == "PLAYER_LOGIN" then
            playerName = GetFullName("player")   -- nome completo incluindo sobrenome
            playerGUID = UnitGUID("player")
            playerKey  = NormKey(playerName)

            -- Migração: se o DB tem a versão truncada (só primeiro nome) do mesmo player,
            -- move os scores para o nome completo e remove a entry antiga.
            if playerName and string.find(playerName, " ") then
                local firstOnly = string.match(playerName, "^(%S+)")
                if firstOnly and firstOnly ~= playerName then
                    for _, view in ipairs(SCORE_STORES) do
                        local s = ScoreStore(view)
                        if s.kills[firstOnly] then
                            s.kills[playerName]  = (s.kills[playerName]  or 0) + (s.kills[firstOnly]  or 0)
                            s.kcount[playerName] = (s.kcount[playerName] or 0) + (s.kcount[firstOnly] or 0)
                            s.kills[firstOnly]  = nil
                            s.kcount[firstOnly] = nil
                            if view == "all" then
                                Print(("Migração: '%s' -> '%s'"):format(firstOnly, playerName))
                            end
                        end
                    end
                end
            end

            -- Semana pode ter virado enquanto estava offline
            EnsureWeek()
            EnsureEntry(playerName)

            -- Checa a virada da semana + estado de evento a cada 30s
            if C_Timer and C_Timer.NewTicker then
                C_Timer.NewTicker(30, function()
                    if EnsureWeek() then
                        EnsureEntry(playerName)
                        Print("|cFFFFD100Novo ranking semanal começou!|r Boa caçada.")
                    end
                    TickEvents()        -- detecta start/end automático de eventos
                    RefreshRankFrame()  -- atualiza contagem regressiva (no-op se fechado)
                end)
            end
            ScheduleRosterRefresh()
            if C_Timer and C_Timer.After then
                -- Primeira passada em 3s: anuncia meu score e pede os outros
                C_Timer.After(3, function()
                    if IsInGuild() then
                        BroadcastMyScore()                 -- todos sabem meu score
                        Broadcast("REQ:" .. playerName)    -- peço os deles (resposta via WHISPER)
                        Broadcast("BOUNTYREQ:")
                        Broadcast("GBREQ:")
                        Broadcast("EVENTREQ:")
                    end
                end)
                -- Segunda passada em 15s: re-tenta caso alguém tenha falhado o whisper
                C_Timer.After(15, function()
                    if IsInGuild() then
                        Broadcast("REQ:" .. playerName)
                    end
                end)
            end

        elseif event == "PLAYER_TARGET_CHANGED" then
            ScanUnit("target")

        elseif event == "UPDATE_MOUSEOVER_UNIT" then
            ScanUnit("mouseover")

        elseif event == "NAME_PLATE_UNIT_ADDED" then
            ScanUnit(arg1)

        elseif event == "GUILD_ROSTER_UPDATE" then
            RefreshGuildRoster()
            RefreshRankFrame()

        elseif event == "PLAYER_DEAD" then
            -- Opt-in: desligado por padrão. Toggle via /gnomo deathannounce
            if not GnomeHunterDB.opts.announceDeath then return end
            if not IsInGuild() then return end
            -- Ignora mortes em instâncias (dungeon/raid/BG/arena) - só open-world PvP
            if IsInInstance then
                local inst = IsInInstance()
                if inst then return end
            end
            -- Precisa identificar o killer com segurança, caso contrário
            -- não anuncia (evita PvE, fall damage, DoT residual, alvo errado)
            local killerUnit = FindLikelyKiller()
            if not killerUnit then return end
            local killer = GetFullName(killerUnit)
            if not killer then return end
            local killerLvl
            if UnitLevel then
                local lvl = Readable(UnitLevel(killerUnit))
                if type(lvl) == "number" and lvl > 0 then killerLvl = lvl end
            end
            local _, englishRace = UnitRace(killerUnit)
            local killerRace = Readable(englishRace)
            local me = playerName or "Alguém"
            local lvlTag = killerLvl and (" [lvl %d]"):format(killerLvl) or ""
            local msg
            if killerRace == "Gnome" then
                msg = ("%s foi morto pelo gnomo %s%s"):format(me, killer, lvlTag)
            else
                msg = ("%s foi morto por %s%s"):format(me, killer, lvlTag)
            end
            SafeChat(msg, "GUILD")

        elseif event == "PARTY_KILL" then
            local attackerGUID = Readable(arg1)
            local targetGUID   = Readable(arg2)
            if not attackerGUID or not targetGUID then return end
            if attackerGUID ~= playerGUID then return end
            local race  = guidRace[targetGUID]
            local name  = guidName[targetGUID]
            local gname = guidGuild[targetGUID]
            local lvl   = guidLevel[targetGUID]

            local pb = GnomeHunterDB.bounty
            local gb = GnomeHunterDB.guildBounty
            local isPlayerBounty = pb and pb.name and name
                and NameMatchesBounty(name, pb.name)
            local isGuildBounty = gb and gb.name and gname
                and string.lower(gname) == string.lower(gb.name)

            if race == "Gnome" or isPlayerBounty or isGuildBounty then
                RegisterKill(name or "um inimigo", race, gname, lvl)
                RefreshRankFrame()
                guidRace[targetGUID]  = nil
                guidName[targetGUID]  = nil
                guidGuild[targetGUID] = nil
                guidLevel[targetGUID] = nil
            end

        elseif event == "CHAT_MSG_ADDON" then
            local prefix, message, channel, sender = arg1, arg2, arg3, arg4
            if prefix ~= ADDON_PREFIX or not sender then return end
            local senderName = string.match(sender, "^([^-]+)") or sender
            if senderName == playerName then return end
            local cmd = string.match(message, "^([^:]+):")

            if cmd == "SCORE" then
                -- v2.4.3+: SCORE:name:pts:kcount
                local _, _, who, pts, kc = string.find(message, "^SCORE:([^:]+):(%d+):(%d+)$")
                if not who then
                    -- v2.4.x: SCORE:name:pts
                    _, _, who, pts = string.find(message, "^SCORE:([^:]+):(%d+)$")
                    kc = pts   -- fallback: assume 1pt por kill
                end
                if who and pts then
                    -- Se o sender mandou só o primeiro nome (addon antigo), promove
                    -- para nome completo usando o guild roster
                    local full = FindFullNameInRoster(who)
                    if full and full ~= who then
                        -- Limpa a entry curta pra não ficar duplicada
                        GnomeHunterDB.kills[who]  = nil
                        GnomeHunterDB.kcount[who] = nil
                        who = full
                    end
                    GnomeHunterDB.kills[who]  = tonumber(pts)
                    GnomeHunterDB.kcount[who] = tonumber(kc)
                    RefreshRankFrame()
                end

            elseif cmd == "WSCORE" then
                -- v2.5.0+: WSCORE:name:weekId:pts:kcount
                local _, _, who, wk, pts, kc = string.find(message, "^WSCORE:([^:]+):(%-?%d+):(%d+):(%d+)$")
                if who then
                    EnsureWeek()
                    local w = GnomeHunterDB.weekly
                    -- Só aceita score da semana ATUAL (score de semana passada
                    -- de quem ficou offline na virada é descartado)
                    if tonumber(wk) == w.weekId then
                        local full = FindFullNameInRoster(who)
                        if full and full ~= who then
                            w.kills[who]  = nil
                            w.kcount[who] = nil
                            who = full
                        end
                        w.kills[who]  = tonumber(pts)
                        w.kcount[who] = tonumber(kc)
                        RefreshRankFrame()
                    end
                end

            elseif cmd == "REQ" then
                -- Whisper direto pra quem pediu, não polui a guild com N respostas
                SendMyScore(sender)

            -- PLAYER BOUNTY - só aceita de oficial
            elseif cmd == "BOUNTY" then
                if not IsRosterOfficer(senderName) then return end
                -- formato v2.4: BOUNTY:name:race:setBy:setAt
                -- formato v2.3: BOUNTY:name:race:setBy  (sem setAt, tratamos como 0)
                local _, _, bname, brace, bby, bat = string.find(message, "^BOUNTY:([^:]+):([^:]+):([^:]+):(%d+)$")
                if not bname then
                    _, _, bname, brace, bby = string.find(message, "^BOUNTY:([^:]+):([^:]+):(.+)$")
                    bat = "0"
                end
                if bname then
                    local newAt = tonumber(bat) or 0
                    local cur = GnomeHunterDB.bounty
                    local curAt = (cur and cur.setAt) or 0
                    -- só atualiza se o update é mais novo (ou não temos nada)
                    if newAt >= curAt then
                        -- só anuncia se é REALMENTE um bounty diferente
                        local reallyNew = (not cur) or cur.name ~= bname or newAt > curAt
                        GnomeHunterDB.bounty = { name = bname, race = brace, setBy = bby, setAt = newAt }
                        wipe(lastAlertAt)
                        if reallyNew then
                            Print(("|cFFFFD100Novo bounty da guild:|r %s (%s) por %s"):format(bname, brace or "?", bby or "?"))
                        end
                        RefreshRankFrame()
                    end
                end

            elseif cmd == "BOUNTYCLR" then
                if not IsRosterOfficer(senderName) then return end
                -- formato v2.4: BOUNTYCLR:clearedAt
                -- formato v2.3: BOUNTYCLR:  (sem timestamp -> ignora para evitar wipe fantasma)
                local _, _, clrAt = string.find(message, "^BOUNTYCLR:(%d+)$")
                clrAt = tonumber(clrAt)
                if clrAt then
                    local curAt = (GnomeHunterDB.bounty and GnomeHunterDB.bounty.setAt) or 0
                    if clrAt > curAt then
                        GnomeHunterDB.bounty = nil
                        GnomeHunterDB.bountyClearedAt = clrAt
                        wipe(lastAlertAt)
                        Print("|cFFFFD100Bounty de player removido.|r")
                        RefreshRankFrame()
                    end
                end
                -- Sem timestamp: ignorado (consertar bug do bounty sumindo)

            elseif cmd == "BOUNTYREQ" then
                -- SÓ responde se oficial E tem bounty ativo - e via WHISPER pra não spammar
                if IsGuildOfficer() and GnomeHunterDB.bounty then
                    SendBounty(sender)
                end

            -- GUILD BOUNTY - só aceita de oficial
            elseif cmd == "GBNTY" then
                if not IsRosterOfficer(senderName) then return end
                local _, _, gbname, gbby, gbat = string.find(message, "^GBNTY:([^:]+):([^:]+):(%d+)$")
                if gbname then
                    local newAt = tonumber(gbat) or 0
                    local cur = GnomeHunterDB.guildBounty
                    local curAt = (cur and cur.setAt) or 0
                    if newAt >= curAt then
                        local reallyNew = (not cur) or cur.name ~= gbname or newAt > curAt
                        GnomeHunterDB.guildBounty = { name = gbname, setBy = gbby, setAt = newAt }
                        wipe(lastAlertAt)
                        if reallyNew then
                            Print(("|cFFFFD100Novo guild bounty:|r <%s> por %s"):format(gbname, gbby or "?"))
                        end
                        RefreshRankFrame()
                    end
                end

            elseif cmd == "GBCLR" then
                if not IsRosterOfficer(senderName) then return end
                local _, _, clrAt = string.find(message, "^GBCLR:(%d+)$")
                clrAt = tonumber(clrAt)
                if clrAt then
                    local curAt = (GnomeHunterDB.guildBounty and GnomeHunterDB.guildBounty.setAt) or 0
                    if clrAt > curAt then
                        GnomeHunterDB.guildBounty = nil
                        GnomeHunterDB.guildBountyClearedAt = clrAt
                        wipe(lastAlertAt)
                        Print("|cFFFFD100Guild bounty removido.|r")
                        RefreshRankFrame()
                    end
                end

            elseif cmd == "GBREQ" then
                if IsGuildOfficer() and GnomeHunterDB.guildBounty then
                    SendGuildBounty(sender)
                end

            -- EVENTOS - só oficiais podem anunciar/cancelar
            elseif cmd == "EVENT" then
                if not IsRosterOfficer(senderName) then return end
                -- EVENT:id:startAt:endAt:setBy:setAt:name
                local _, _, eid, sAt, eAt, sBy, sTime, ename =
                    string.find(message, "^EVENT:([^:]+):(%d+):(%d+):([^:]+):(%d+):(.+)$")
                if not eid then return end
                sAt, eAt, sTime = tonumber(sAt), tonumber(eAt), tonumber(sTime)
                if not (sAt and eAt and sTime) or eAt <= sAt then return end
                local existing = GnomeHunterDB.events[eid]
                -- Rejeita se já cancelamos este eventId com timestamp mais novo
                local cancelAt = GnomeHunterDB.eventCancelsAt[eid]
                if cancelAt and cancelAt >= sTime then return end
                -- Só aceita update se é mais novo
                if existing and existing.setAt and existing.setAt > sTime then return end
                GnomeHunterDB.events[eid] = {
                    id       = eid,
                    name     = ename,
                    startAt  = sAt,
                    endAt    = eAt,
                    setBy    = sBy,
                    setAt    = sTime,
                    kills    = (existing and existing.kills)  or {},
                    kcount   = (existing and existing.kcount) or {},
                    finished = false,
                    cancelled = false,
                    announcedStart = existing and existing.announcedStart or false,
                    announcedEnd   = existing and existing.announcedEnd   or false,
                }
                if not existing then
                    table.insert(GnomeHunterDB.eventHistoryIds, eid)
                    PruneEventHistory()
                    Print(("|cFFFFD100Novo evento da guild:|r '%s' (ate %s) por %s"):format(
                        ename, FormatBRT(eAt), sBy or "?"))
                end
                TickEvents()
                RefreshRankFrame()

            elseif cmd == "EVENTCLR" then
                if not IsRosterOfficer(senderName) then return end
                local _, _, eid, clrAt = string.find(message, "^EVENTCLR:([^:]+):(%d+)$")
                clrAt = tonumber(clrAt)
                if not (eid and clrAt) then return end
                local e = GnomeHunterDB.events[eid]
                if e and e.setAt and e.setAt > clrAt then return end
                GnomeHunterDB.eventCancelsAt[eid] = math.max(
                    GnomeHunterDB.eventCancelsAt[eid] or 0, clrAt)
                if e then
                    e.cancelled = true
                    if GnomeHunterDB.activeEventId == eid then
                        GnomeHunterDB.activeEventId = nil
                    end
                    Print(("|cFFFFD100Evento '%s' cancelado por oficial.|r"):format(e.name or eid))
                    RefreshRankFrame()
                end

            elseif cmd == "EVENTREQ" then
                -- Oficiais respondem com o evento ativo atual (via whisper)
                if IsGuildOfficer() and GnomeHunterDB.activeEventId then
                    SendEvent(sender, GnomeHunterDB.activeEventId)
                end
                -- Todos (não só oficiais) também respondem com seu ESCORE do evento ativo
                if GnomeHunterDB.activeEventId then
                    SendEventScore(sender, GnomeHunterDB.activeEventId)
                end

            elseif cmd == "ESCORE" then
                -- ESCORE:eventId:player:pts:kcount
                local _, _, eid, who, pts, kc =
                    string.find(message, "^ESCORE:([^:]+):([^:]+):(%d+):(%d+)$")
                if not eid then return end
                local e = GnomeHunterDB.events[eid]
                if not e or e.cancelled then return end
                -- Normalize nome via roster
                local full = FindFullNameInRoster(who)
                if full and full ~= who then
                    if e.kills[who]  then e.kills[who]  = nil end
                    if e.kcount[who] then e.kcount[who] = nil end
                    who = full
                end
                -- Mesma política de MAX usada no SCORE/WSCORE
                e.kills[who]  = math.max(e.kills[who]  or 0, tonumber(pts) or 0)
                e.kcount[who] = math.max(e.kcount[who] or 0, tonumber(kc)  or 0)
                RefreshRankFrame()

            -- Reset global - só aceita de oficial e com timestamp mais novo que o último reset
            elseif cmd == "RESETALL" then
                if not IsRosterOfficer(senderName) then return end
                local _, _, at = string.find(message, "^RESETALL:(%d+)$")
                at = tonumber(at)
                if not at then return end
                if at <= (GnomeHunterDB.resetAt or 0) then return end
                GnomeHunterDB.kills  = {}
                GnomeHunterDB.kcount = {}
                wipe(GnomeHunterDB.weekly.kills)
                wipe(GnomeHunterDB.weekly.kcount)
                if playerName then EnsureEntry(playerName) end
                GnomeHunterDB.resetAt = at
                Print(("|cFFFFD100Ranking zerado pelo oficial %s.|r"):format(senderName or "?"))
                RefreshRankFrame()
            end
        end
    end

    -- =================================================================
    -- Setup final
    -- =================================================================
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        pcall(C_ChatInfo.RegisterAddonMessagePrefix, ADDON_PREFIX)
    end

    _G.SLASH_GNOMEHUNTER1 = "/gnomo"
    _G.SLASH_GNOMEHUNTER2 = "/gnome"
    _G.SLASH_GNOMEHUNTER3 = "/gnomehunter"
    SlashCmdList["GNOMEHUNTER"] = SlashHandler

    self:SetScript("OnEvent", MainHandler)

    local function SafeReg(evt)
        local ok = pcall(self.RegisterEvent, self, evt)
        if not ok then Print("Evento não registrado: " .. evt) end
    end

    SafeReg("PLAYER_LOGIN")
    SafeReg("PLAYER_TARGET_CHANGED")
    SafeReg("UPDATE_MOUSEOVER_UNIT")
    SafeReg("NAME_PLATE_UNIT_ADDED")
    SafeReg("PARTY_KILL")
    SafeReg("PLAYER_DEAD")
    SafeReg("GUILD_ROSTER_UPDATE")
    SafeReg("CHAT_MSG_ADDON")

    BuildMinimapButton()

    Print("Carregado (v" .. VERSION .. "). /gnomo ui para abrir a janela.")
end)
