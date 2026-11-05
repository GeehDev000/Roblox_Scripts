--[[
    TYCOON HELPER - "Tycoon, but one dropper" (Xeno)

    Construído SÓ com o que foi observado nos dumps/logs. Nada de remotes inventados.

    O QUE É BASEADO EM EVIDÊNCIA (observado nos logs):
      - Net (RemoteEvent) manda eventos do servidor com o nome no 1º argumento:
          "Pail"      {Id, Life, Pos}   -> balde de doces apareceu (Workspace.CandyPail)
          "PailGone"  {Got, Id}         -> balde coletado/sumiu
          "CrateGone" {Got, Id}         -> caixa misteriosa coletada/sumiu
          "Ev"        {K="Surge", P="Cell", Id, Candy, Until} -> coleta de célula Surge
          Workspace.EventFX.EvCell      -> modelo visual da célula Surge
          "Ev"        {K="Airdrop", P="Live", Crates={Id, L, D, A, G}}
                                          -> horários de soltura/chegada e posições
          "Ev"        {K="Airdrop", P="Got", Id, Name, By}
                                          -> confirmação de coleta do Airdrop
          "Mystery"   {Kind, Source, Amount}
      - Atributos do Player: WheelNext, WheelSpins, QuestsReady, Cash, RebirthCost, Rebirths, Loaded,
        OdUntil e OdReady (janela ativa/recarga do Overdrive), OdCharge (carga observada)
      - Eventos Overdrive {Until, Ready} e OverdriveEnd {Ready} também informam o ciclo do Overdrive.
      - WheelNext vira (hora do servidor + ~900s) depois de girar a roleta.
      - O balde sumiu com o jogador a ~2,5 studs dele (coleta por proximidade, sem prompt).
      - Botões do HUD: HUD.Main.Right.Spin, HUD.Main.Left.Rebirth

    O QUE É SUPOSIÇÃO (por isso cada função mostra o resultado REAL na interface):
      - Candy/Mystery: teleportar até o objeto coleta (proximidade). Verificado pelo evento
        PailGone/CrateGone; se não vier, a interface mostra "não coletou".
      - Surge Cell: procura o modelo visual EvCell em Workspace.EventFX e calcula a posição
        pelo bounding box. A proximidade como gatilho é uma inferência; só conta sucesso
        quando chega Ev {K="Surge", P="Cell"} e um atributo local (Candy/SurgeUntil) muda.
      - Airdrop: L é tratado como a posição no solo; A coincide com a chegada da caixa
        (D é anterior, quando ela é solta). O teleporte é feito após A e só conta com Got.
        A proximidade como gatilho é uma inferência.
      - Spin: ReplicatedStorage.Remotes.Action:InvokeServer("Spin") foi fornecido
        pelo desenvolvedor. A disponibilidade é verificada por WheelNext/WheelSpins.
      - Rebirth: continua usando o botão real do HUD, com confirmação pelo estado.
      - AutoRebirthOn local foi removido: SetAttribute no cliente não equivale a habilitar
        a opção no servidor.

    COMO ADICIONAR UMA FUNÇÃO NOVA: crie com newFeature{...} na seção "FUNÇÕES"
    (Id, Name, Category, Interval, Tick, OnEnable, OnDisable). A GUI e o agendador a incluem sozinhos.
]]

---------------------------------------------------------------------
-- Instância única: executar de novo fecha a anterior
---------------------------------------------------------------------
local env = (getgenv and getgenv()) or _G

-- Camada de compatibilidade: detecta recursos opcionais do executor.
local Compat = {}
Compat.GetHui = type(gethui) == "function" and gethui or nil
Compat.Request = type(request) == "function" and request
    or (syn and type(syn.request) == "function" and syn.request)
    or (http and type(http.request) == "function" and http.request) or nil
Compat.VirtualInput = nil
pcall(function() Compat.VirtualInput = game:GetService("VirtualInputManager") end)
Compat.Capabilities = {
    HiddenGui = Compat.GetHui ~= nil,
    HttpRequest = Compat.Request ~= nil,
    VirtualInput = Compat.VirtualInput ~= nil,
}
local function safeRequest(options)
    if not Compat.Request then return nil, "HTTP request indisponível" end
    local ok, result = pcall(Compat.Request, options)
    if not ok then return nil, tostring(result) end
    return result
end
if env.__TBOD_AUTO and env.__TBOD_AUTO.Destroy then
    pcall(env.__TBOD_AUTO.Destroy)
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local LocalPlayer = Players.LocalPlayer
local okVim, VirtualInputManager = pcall(function() return game:GetService("VirtualInputManager") end)
if not okVim then VirtualInputManager = nil end

---------------------------------------------------------------------
-- Fatos do jogo (todos vistos nos logs; ver cabeçalho)
---------------------------------------------------------------------
local GAME = {
    Events = { PailSpawn = "Pail", PailGone = "PailGone", CrateGone = "CrateGone", Mystery = "Mystery" },
    CandyModelName = "CandyPail",   -- Workspace.CandyPail (Model) com MeshPart "CandyPail"
    CandyPartName = "CandyPail",
    CrateModelName = "MysteryCrate",-- Model "MysteryCrate" (5 Parts); pai exato não foi registrado
    SurgeCellModelName = "EvCell",  -- Workspace.EventFX.EvCell (Model observado no log)
    Hud = {
        Spin = "HUD.Main.Right.Spin",
        Rebirth = "HUD.Main.Left.Rebirth",
            },
}

local CONFIG = {
    TeleportHeightOffset = 2,    -- studs acima do alvo (balde foi coletado a ~2,5 studs)
    CollectTimeout = 4,          -- segundos esperando PailGone/CrateGone após teleportar
    CrateMaxAttempts = 3,
    CrateRetryDelay = 8,
    SpinTimeout = 5,
    RebirthTimeout = 8,
    -- botões com essas palavras nunca são clicados (evita compras/Robux)
    ForbiddenWords = { "robux", "r$", "skip", "buy", "comprar", "gift", "vip", "pass" },
}

---------------------------------------------------------------------
-- Estado geral e utilitários
---------------------------------------------------------------------
local alive = true
local connections = {}

local function track(conn)
    connections[#connections + 1] = conn
    return conn
end

local function log(msg)
    pcall(print, "[TycoonHelper] " .. tostring(msg))
end

-- Espera até cond() ser verdadeira, o tempo acabar ou o script ser encerrado
local function waitUntil(cond, timeout, step, onStep)
    local t0 = os.clock()
    while alive and os.clock() - t0 < timeout do
        local ok, res = pcall(cond)
        if ok and res then return true end
        if onStep then pcall(onStep) end
        task.wait(step or 0.1)
    end
    if not alive then return false end
    local ok, res = pcall(cond)
    return (ok and res) and true or false
end

local function getNum(attrName)
    local v = LocalPlayer:GetAttribute(attrName)
    if type(v) == "number" then return v end

    -- Alguns estados podem aparecer como ValueObjects em vez de atributos.
    local candidates = { LocalPlayer:FindFirstChild(attrName) }
    local leaderstats = LocalPlayer:FindFirstChild("leaderstats")
    if leaderstats then
        candidates[#candidates + 1] = leaderstats:FindFirstChild(attrName)
    end
    for _, obj in ipairs(candidates) do
        if obj and (obj:IsA("NumberValue") or obj:IsA("IntValue")) then
            return obj.Value
        elseif obj and obj:IsA("StringValue") then
            local parsed = tonumber(obj.Value)
            if parsed ~= nil then return parsed end
        end
    end
    return nil
end

local function fmtDuration(s)
    if s < 0 then s = 0 end
    return string.format("%d:%02d", math.floor(s / 60), math.floor(s % 60))
end

local function stripRichText(s)
    return (tostring(s):gsub("<[^>]->", ""))
end

---------------------------------------------------------------------
-- Eventos do servidor (Net.OnClientEvent) -> estado compartilhado
---------------------------------------------------------------------
local netState = {
    candyGone = {},       -- [Id] = true quando PailGone chegou
    candyTotal = 0,       -- soma dos "Got" vistos
    crateGoneStamp = 0,   -- incrementa a cada CrateGone com Got=true
    crateTotal = 0,
    surgeCellStamp = 0,   -- incrementa quando chega Ev {K="Surge", P="Cell"}
    surgeCellTotal = 0,
    airdrop = nil,        -- último evento Airdrop Live: crates com Id, L, D e A
    overdriveUntil = nil, -- timestamp recebido no evento Overdrive
    overdriveReady = nil,-- timestamp de próxima disponibilidade
    onPail = nil,         -- callback (data) preenchido pela função Candy
    obbyReadyAt = { diamond = nil, golden = nil }, -- cooldowns independentes por Obby
    obbyClaimStamp = { diamond = 0, golden = 0 },   -- confirmações separadas pelo Title
    obbyLastTitle = { diamond = nil, golden = nil },
    obbyLastCash = { diamond = nil, golden = nil },
    boughtStamp = 0,
    lastBoughtId = nil,
}

local function handleNetEvent(name, data)
    if name == "Bought" and type(data) == "table" then
        netState.boughtStamp = netState.boughtStamp + 1
        netState.lastBoughtId = tostring(data.Id or "")
    end

    -- O servidor usa o mesmo evento "Obby", mas o Title identifica qual recompensa foi entregue.
    if name == "Obby" and type(data) == "table" then
        local title = tostring(data.Title or "")
        local lowerTitle = title:lower()
        local obbyKey = nil
        if lowerTitle:find("power plant", 1, true) then
            obbyKey = "diamond"
        elseif lowerTitle:find("obby", 1, true) then
            obbyKey = "golden"
        end
        if obbyKey then
            netState.obbyClaimStamp[obbyKey] = netState.obbyClaimStamp[obbyKey] + 1
            netState.obbyLastTitle[obbyKey] = title
            netState.obbyLastCash[obbyKey] = tonumber(data.Cash)
        end
    elseif name == "Toast" and type(data) == "table" and type(data.Text) == "string" then
        -- Os textos são distintos: Power Plant e obby possuem cooldowns próprios.
        local lowerText = data.Text:lower()
        local obbyKey, minutes, seconds
        minutes, seconds = lowerText:match("next power plant reward in%s+(%d+):(%d+)")
        if minutes then
            obbyKey = "diamond"
        else
            minutes, seconds = lowerText:match("next obby reward in%s+(%d+):(%d+)")
            if minutes then obbyKey = "golden" end
        end
        if obbyKey and minutes and seconds then
            netState.obbyReadyAt[obbyKey] = Workspace:GetServerTimeNow() + tonumber(minutes) * 60 + tonumber(seconds)
        end
    elseif name == "Overdrive" and type(data) == "table" then
        netState.overdriveUntil = tonumber(data.Until) or netState.overdriveUntil
        netState.overdriveReady = tonumber(data.Ready) or netState.overdriveReady
    elseif name == "OverdriveEnd" and type(data) == "table" then
        netState.overdriveReady = tonumber(data.Ready) or netState.overdriveReady
    elseif name == GAME.Events.PailSpawn and type(data) == "table" then
        if netState.onPail then netState.onPail(data) end
    elseif name == GAME.Events.PailGone and type(data) == "table" then
        if data.Id ~= nil then netState.candyGone[data.Id] = true end
        if type(data.Got) == "number" then netState.candyTotal = netState.candyTotal + data.Got end
    elseif name == GAME.Events.CrateGone and type(data) == "table" then
        if data.Got == true then
            netState.crateGoneStamp = netState.crateGoneStamp + 1
            netState.crateTotal = netState.crateTotal + 1
        end
    elseif name == "Ev" and type(data) == "table" and data.K == "Surge" and data.P == "Cell" then
        netState.surgeCellStamp = netState.surgeCellStamp + 1
        netState.surgeCellTotal = netState.surgeCellTotal + 1
    elseif name == "Ev" and type(data) == "table" and data.K == "Airdrop" then
        if data.P == "Live" and type(data.Crates) == "table" then
            local run = {
                StartedAt = tonumber(data.T1) or Workspace:GetServerTimeNow(),
                EndsAt = tonumber(data.T3),
                Crates = {},
            }
            for _, raw in ipairs(data.Crates) do
                if type(raw) == "table" and raw.Id ~= nil and typeof(raw.L) == "Vector3" then
                    run.Crates[#run.Crates + 1] = {
                        Id = raw.Id,
                        Pos = raw.L,
                        ReleaseAt = tonumber(raw.D) or 0,
                        AvailableAt = tonumber(raw.A) or tonumber(raw.D) or 0,
                        Golden = raw.G == true,
                        Got = false,
                        GotBy = nil,
                        GotByLocalPlayer = false,
                        Tries = 0,
                        LastTry = 0,
                        Finished = false,
                    }
                end
            end
            table.sort(run.Crates, function(a, b)
                if a.AvailableAt == b.AvailableAt then
                    return tostring(a.Id) < tostring(b.Id)
                end
                return a.AvailableAt < b.AvailableAt
            end)
            netState.airdrop = run
        elseif data.P == "Got" and data.Id ~= nil and netState.airdrop then
            for _, crate in ipairs(netState.airdrop.Crates) do
                if crate.Id == data.Id then
                    crate.Got = true
                    crate.GotBy = data.Name
                    crate.GotByLocalPlayer = data.Name == LocalPlayer.Name
                        or data.Name == LocalPlayer.DisplayName
                        or data.By == LocalPlayer.UserId
                    break
                end
            end
        end
    end
end

local function startNetListener()
    task.spawn(function()
        local remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
        local net = remotes and remotes:WaitForChild("Net", 10)
        if not net or not net:IsA("RemoteEvent") then
            log("ReplicatedStorage.Remotes.Net não encontrado; eventos de doce/caixa indisponíveis")
            return
        end
        if not alive then return end
        track(net.OnClientEvent:Connect(function(name, data)
            if not alive then return end
            if type(name) == "string" then pcall(handleNetEvent, name, data) end
        end))
    end)
end

---------------------------------------------------------------------
-- Teleporte para coleta por proximidade (usado por Candy e Crate)
---------------------------------------------------------------------
local moveLock = false -- só um teleporte por vez

local function getCharacterParts()
    local char = LocalPlayer.Character
    if not char then return nil end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    local hum = char:FindFirstChildOfClass("Humanoid")
    if hrp and hum and hum.Health > 0 then return hrp, hum end
    return nil
end

-- Vai até pos, espera doneFn() ficar verdadeira (ou timeout) e VOLTA ao ponto original.
local function teleportCollect(pos, doneFn, timeout)
    local hrp = getCharacterParts()
    if not hrp then return false, "sem personagem" end
    local original = hrp.CFrame
    local target = CFrame.new(pos + Vector3.new(0, CONFIG.TeleportHeightOffset, 0))
    local function place()
        local h = getCharacterParts()
        if h then
            h.CFrame = target
            h.AssemblyLinearVelocity = Vector3.zero
        end
    end
    place()
    local ok = waitUntil(doneFn, timeout, 0.15, place)
    local h2 = getCharacterParts()
    if h2 then
        h2.CFrame = original
        h2.AssemblyLinearVelocity = Vector3.zero
    end
    if ok then return true end
    return false, "não coletou"
end

---------------------------------------------------------------------
-- Interação com a interface (usada por Spin e Rebirth)
---------------------------------------------------------------------
local uiBusy = false

local function withUiLock(fn)
    local t0 = os.clock()
    while uiBusy and alive and os.clock() - t0 < 15 do task.wait(0.2) end
    if uiBusy or not alive then return false, "interface ocupada" end
    uiBusy = true
    local ok, r1, r2 = pcall(fn)
    uiBusy = false
    if not ok then return false, tostring(r1) end
    return r1, r2
end

local function resolvePath(root, path)
    local cur = root
    for part in string.gmatch(path, "[^%.]+") do
        cur = cur and cur:FindFirstChild(part)
    end
    return cur
end

local function isVisible(gui)
    local ok, res = pcall(function()
        if not gui:IsA("GuiObject") or not gui.Visible then return false end
        if gui.AbsoluteSize.X <= 0 or gui.AbsoluteSize.Y <= 0 then return false end
        local sg = gui:FindFirstAncestorWhichIsA("ScreenGui")
        if sg and not sg.Enabled then return false end
        local p = gui.Parent
        while p and p:IsA("GuiObject") do
            if not p.Visible then return false end
            p = p.Parent
        end
        return true
    end)
    return ok and res
end

local function labelText(obj)
    local ok, t = pcall(function()
        if obj:IsA("TextButton") and obj.Text ~= "" then return obj.Text end
        local parts = {}
        for _, d in ipairs(obj:GetDescendants()) do
            if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Text ~= "" then
                parts[#parts + 1] = d.Text
                if #parts >= 6 then break end
            end
        end
        return table.concat(parts, " ")
    end)
    return stripRichText(ok and t or "")
end

local function containsAny(text, words)
    text = text:lower()
    for _, w in ipairs(words) do
        if text:find(w, 1, true) then return true end
    end
    return false
end

-- Primeiro botão clicável dentro de root (ou o próprio root, se for botão)
local function findClickable(root)
    if not root then return nil end
    if root:IsA("GuiButton") and isVisible(root) and root.Active then
        return root
    end
    for _, d in ipairs(root:GetDescendants()) do
        if d:IsA("GuiButton") and isVisible(d) and d.Active then
            return d
        end
    end
    if root:IsA("GuiObject") and isVisible(root) then return root end
    return nil
end

-- Botões VISÍVEIS cujo nome/texto contém alguma palavra de keywords (fora de excludeRoot)
local function findButtons(playerGui, keywords, excludeRoot)
    local found = {}
    for _, d in ipairs(playerGui:GetDescendants()) do
        if d:IsA("GuiButton") and isVisible(d) then
            if not (excludeRoot and (d == excludeRoot or d:IsDescendantOf(excludeRoot))) then
                local text = d.Name .. " " .. labelText(d)
                if containsAny(text, keywords) and not containsAny(text, CONFIG.ForbiddenWords) then
                    found[#found + 1] = d
                    if #found >= 15 then break end
                end
            end
        end
    end
    return found
end

-- Procura o controle NATIVE do jogo que liga o Auto Rebirth. Não altera
-- atributos localmente: a ativação precisa vir do próprio botão da interface.
local function findAutoRebirthToggle(playerGui)
    for _, d in ipairs(playerGui:GetDescendants()) do
        if d:IsA("GuiButton") and isVisible(d) then
            local names = { d.Name, labelText(d) }
            local parent = d.Parent
            for _ = 1, 3 do
                if not parent then break end
                names[#names + 1] = parent.Name
                parent = parent.Parent
            end
            local identity = table.concat(names, " "):lower()
            if identity:find("auto", 1, true) and identity:find("rebirth", 1, true)
                and not containsAny(identity, CONFIG.ForbiddenWords) then
                return d
            end
        end
    end
    return nil
end

-- Métodos de clique disponíveis neste executor (ordem de preferência)
local CLICK_METHODS = { "Activate" }
if firesignal then
    CLICK_METHODS[#CLICK_METHODS + 1] = "Activated"
    CLICK_METHODS[#CLICK_METHODS + 1] = "MouseButton1Click"
end
if getconnections then CLICK_METHODS[#CLICK_METHODS + 1] = "Connections" end
if VirtualInputManager then CLICK_METHODS[#CLICK_METHODS + 1] = "Mouse" end

local function mouseClick(btn)
    local center = btn.AbsolutePosition + btn.AbsoluteSize / 2
    local y = center.Y
    local sg = btn:FindFirstAncestorWhichIsA("ScreenGui")
    if sg and not sg.IgnoreGuiInset then y = y + GuiService:GetGuiInset().Y end
    pcall(function()
        VirtualInputManager:SendMouseMoveEvent(center.X, y, game)
    end)
    task.wait(0.04)
    VirtualInputManager:SendMouseButtonEvent(center.X, y, 0, true, game, 0)
    task.wait(0.07)
    VirtualInputManager:SendMouseButtonEvent(center.X, y, 0, false, game, 0)
    return true
end

local function pressWith(btn, method)
    local isButton = btn:IsA("GuiButton")
    if method == "Activate" and isButton then
        local ok = pcall(function() btn:Activate() end)
        return ok
    elseif method == "Activated" and firesignal and isButton then
        return (pcall(firesignal, btn.Activated))
    elseif method == "MouseButton1Click" and firesignal and isButton then
        return (pcall(firesignal, btn.MouseButton1Click))
    elseif method == "Connections" and getconnections and isButton then
        local fired = false
        for _, sig in ipairs({ btn.Activated, btn.MouseButton1Click }) do
            local ok, conns = pcall(getconnections, sig)
            if ok and type(conns) == "table" then
                for _, c in ipairs(conns) do
                    if pcall(function() c:Fire() end) then fired = true end
                end
            end
        end
        return fired
    elseif method == "Mouse" and VirtualInputManager then
        return (pcall(mouseClick, btn))
    end
    return false
end

local function orderedMethods(cached)
    local list = {}
    if cached then list[1] = cached end
    for _, m in ipairs(CLICK_METHODS) do
        if m ~= cached then list[#list + 1] = m end
    end
    return list
end

--[[
    Fluxo genérico: clica no botão do HUD, procura um botão de confirmação/resgate
    (spec.followKeywords) e clica; depois VERIFICA com spec.isSuccess(baseline).
    Testa os métodos de clique em ordem até um ter efeito verificado.
    spec = { hudPath, followKeywords, maxFollow, baseline(), isSuccess(baseline), timeout }
]]
local function runUiFlow(f, spec)
    if #CLICK_METHODS == 0 then
        return false, "executor sem método de clique disponível"
    end
    local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not playerGui then return false, "sem PlayerGui" end
    local hudRoot = resolvePath(playerGui, spec.hudPath)
    if not hudRoot then
        return false, "caminho do HUD não encontrado (" .. spec.hudPath .. ")"
    end
    local hudBtn = findClickable(hudRoot)
    if not hudBtn then
        return false, "botão do HUD oculto/inativo (" .. spec.hudPath .. ")"
    end

    for _, method in ipairs(orderedMethods(f.Method)) do
        if not alive or not f.Enabled then return false, "cancelado" end
        local baseline = spec.baseline()
        local clickOk = pressWith(hudBtn, method)
        if clickOk then
            -- Aguarda a possível abertura de uma confirmação/modal após o clique principal.
            local follow = {}
            if spec.followKeywords then
                local deadline = os.clock() + 1.0
                repeat
                    follow = findButtons(playerGui, spec.followKeywords, hudRoot)
                    if #follow > 0 then break end
                    task.wait(0.1)
                until not alive or not f.Enabled or os.clock() >= deadline
            end
            for i, b in ipairs(follow) do
                if i > (spec.maxFollow or 1) then break end
                if isVisible(b) then
                    pressWith(b, method)
                    task.wait(0.35)
                end
            end
            if waitUntil(function() return spec.isSuccess(baseline) end, spec.timeout or 5, 0.2) then
                f.Method = method
                return true, method
            end
        end
    end
    return false, "clique no HUD não alterou o estado esperado"
end

---------------------------------------------------------------------
-- FUNÇÕES (registro + agendador)
---------------------------------------------------------------------
local Features = {}

local function newFeature(def)
    def.Enabled = false
    def.Connections, def.Cleanup = {}, {}
    function def:TrackConnection(conn)
        if conn then table.insert(self.Connections, conn) end
        return conn
    end
    function def:TrackCleanup(fn)
        if type(fn) == "function" then table.insert(self.Cleanup, fn) end
        return fn
    end
    function def:CleanResources()
        for _, conn in ipairs(self.Connections) do pcall(function() conn:Disconnect() end) end
        self.Connections = {}
        for i = #self.Cleanup, 1, -1 do pcall(self.Cleanup[i]) end
        self.Cleanup = {}
    end
    def.Status = "Desligado"
    def.Kind = "idle"
    def.Count = 0
    def.Fails = 0
    def.RetryAt = 0
    function def:SetStatus(text, kind)
        self.Status = text
        self.Kind = kind or "idle"
    end
    Features[#Features + 1] = def
    return def
end

local function setEnabled(f, on)
    if f.Enabled == on then return end
    f.Enabled = on
    if on then
        f:SetStatus("Ligado", "idle")
        if f.OnEnable then pcall(f.OnEnable, f) end
    else
        if f.OnDisable then pcall(f.OnDisable, f) end
        if f.CleanResources then f:CleanResources() end
        f:SetStatus("Desligado", "idle")
    end
end

local function startFeatureLoop(f)
    task.spawn(function()
        while alive do
            if f.Enabled and f.Tick then
                local ok, err = pcall(f.Tick, f)
                if not ok then
                    f:SetStatus("Erro: " .. tostring(err):sub(1, 70), "err")
                    log(f.Name .. " erro: " .. tostring(err))
                    task.wait(2)
                end
            end
            task.wait(f.Interval or 1)
        end
    end)
end

-- Aplica espera exponencial depois de uma falha (15s, 30s, 60s, máx. 120s)
local function registerFailure(f, reason)
    f.Fails = f.Fails + 1
    local delay = math.min(15 * 2 ^ (f.Fails - 1), 120)
    f.RetryAt = os.clock() + delay
    f:SetStatus("Falhou: " .. tostring(reason), "err")
    log(f.Name .. " falhou: " .. tostring(reason))
end

---------------------------------------------------------------------
-- 1) AUTO COLLECT CANDIES (evento Pail/PailGone + teleporte por proximidade)
---------------------------------------------------------------------
local candyQueue = {}

local Candy = newFeature({
    Id = "candy", Name = "Auto Collect Candies", Category = "Coleta", Interval = 0.3,
})

local function queueCandy(item)
    candyQueue[#candyQueue + 1] = item
end

netState.onPail = function(data)
    if not Candy.Enabled then return end
    if typeof(data.Pos) ~= "Vector3" then return end
    queueCandy({ Id = data.Id, Pos = data.Pos, born = os.clock(), tries = 0 })
end

function Candy:OnEnable()
    -- Balde que já esteja no mapa quando ligar (sem evento): usa o modelo
    local model = Workspace:FindFirstChild(GAME.CandyModelName)
    if model and model:IsA("Model") then
        local part = model:FindFirstChild(GAME.CandyPartName)
        if part and part:IsA("BasePart") then
            queueCandy({ Id = nil, Pos = part.Position, model = model, born = os.clock(), tries = 0 })
        end
    end
end

function Candy:OnDisable()
    candyQueue = {}
end

local function candyDone(item)
    if item.Id ~= nil and netState.candyGone[item.Id] then return true end
    if item.model and item.model.Parent == nil then return true end
    return false
end

function Candy:Tick()
    local item = candyQueue[1]
    if not item then
        self:SetStatus("Aguardando balde (" .. netState.candyTotal .. " doces vistos)", "idle")
        return
    end
    if candyDone(item) or os.clock() - item.born > 120 then
        table.remove(candyQueue, 1)
        return
    end
    if moveLock then return end
    moveLock = true
    self:SetStatus("Indo até o balde...", "work")
    local ok = teleportCollect(item.Pos, function() return candyDone(item) end, CONFIG.CollectTimeout)
    moveLock = false
    item.tries = item.tries + 1
    if ok then
        table.remove(candyQueue, 1)
        self.Count = self.Count + 1
        self:SetStatus("Balde coletado (" .. self.Count .. " baldes, " .. netState.candyTotal .. " doces)", "ok")
    elseif item.tries >= 2 then
        table.remove(candyQueue, 1)
        self:SetStatus("Não coletou: o teleporte não bastou (balde ignorado)", "err")
        log("balde não coletado após 2 tentativas")
    else
        self:SetStatus("Sem confirmação, tentando de novo...", "warn")
    end
end

---------------------------------------------------------------------
-- 2) AUTO COLLECT MYSTERY BOXES (modelo MysteryCrate + evento CrateGone)
---------------------------------------------------------------------
local knownCrates = {} -- [Model] = { tries, lastTry }

local Crate = newFeature({
    Id = "crate", Name = "Auto Collect Mystery Boxes", Category = "Coleta", Interval = 0.5,
})

-- Posição de coleta: a maior peça "pequena" do modelo (ignora raios/feixes compridos,
-- como o de 90 studs do CandyPail). Fallback: pivô do modelo.
local function crateCollectPosition(model)
    local best, bestVolume
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("BasePart") then
            local s = d.Size
            if math.max(s.X, s.Y, s.Z) <= 30 then
                local volume = s.X * s.Y * s.Z
                if not bestVolume or volume > bestVolume then
                    best, bestVolume = d, volume
                end
            end
        end
    end
    if best then return best.Position end
    local ok, pivot = pcall(function() return model:GetPivot().Position end)
    return ok and pivot or nil
end

local function registerCrate(inst)
    if inst.Name == GAME.CrateModelName and inst:IsA("Model") and not knownCrates[inst] then
        knownCrates[inst] = { tries = 0, lastTry = 0 }
    end
end

function Crate:OnEnable()
    for _, child in ipairs(Workspace:GetChildren()) do registerCrate(child) end
end

function Crate:OnDisable()
    knownCrates = {}
end

function Crate:Tick()
    local target, info
    for model, data in pairs(knownCrates) do
        if model.Parent == nil then
            knownCrates[model] = nil
        elseif data.tries < CONFIG.CrateMaxAttempts and os.clock() - data.lastTry >= CONFIG.CrateRetryDelay then
            target, info = model, data
            break
        end
    end
    if not target then
        self:SetStatus("Aguardando caixa (" .. netState.crateTotal .. " vistas coletadas)", "idle")
        return
    end
    if moveLock then return end
    local pos = crateCollectPosition(target)
    if not pos then
        info.tries = CONFIG.CrateMaxAttempts
        self:SetStatus("Caixa sem posição legível", "err")
        return
    end
    moveLock = true
    info.tries = info.tries + 1
    info.lastTry = os.clock()
    self:SetStatus("Indo até a caixa (tentativa " .. info.tries .. ")...", "work")
    local startStamp = netState.crateGoneStamp
    local ok = teleportCollect(pos, function()
        return netState.crateGoneStamp > startStamp or target.Parent == nil
    end, CONFIG.CollectTimeout)
    moveLock = false
    if ok then
        knownCrates[target] = nil
        self.Count = self.Count + 1
        self:SetStatus("Caixa coletada (" .. self.Count .. ")", "ok")
    elseif info.tries >= CONFIG.CrateMaxAttempts then
        self:SetStatus("Não coletou a caixa: teleporte não bastou (desisti)", "err")
        log("caixa não coletada após " .. info.tries .. " tentativas")
    else
        self:SetStatus("Sem confirmação, nova tentativa em " .. CONFIG.CrateRetryDelay .. "s", "warn")
    end
end

---------------------------------------------------------------------
-- 3) AUTO COLLECT SURGE CELLS (Workspace.EventFX.EvCell + confirmação Ev/Cell)
---------------------------------------------------------------------
local knownSurgeCells = {} -- [Model] = { tries, lastTry, born }

local SurgeCell = newFeature({
    Id = "surge_cells", Name = "Auto Collect Surge Cells", Category = "Coleta", Interval = 0.35,
})

local SURGE_CELL_MAX_ATTEMPTS = 2
local SURGE_CELL_RETRY_DELAY = 1.0
local SURGE_CELL_COLLECT_TIMEOUT = 3.0

-- O pivot do modelo pode não refletir sua posição; usa o bounding box das peças visuais.
-- Retorna o centro X/Z na base do objeto. teleportCollect acrescenta a altura do personagem.
local function surgeCellCollectPosition(model)
    local ok, boxCFrame, boxSize = pcall(function()
        return model:GetBoundingBox()
    end)
    if ok and typeof(boxCFrame) == "CFrame" and typeof(boxSize) == "Vector3" then
        local bottom = boxCFrame.Position - boxCFrame.UpVector * (boxSize.Y * 0.5)
        return Vector3.new(bottom.X, bottom.Y, bottom.Z)
    end

    local best, bestVolume
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("BasePart") then
            local size = d.Size
            if math.max(size.X, size.Y, size.Z) <= 15 then
                local volume = size.X * size.Y * size.Z
                if not bestVolume or volume > bestVolume then
                    best, bestVolume = d, volume
                end
            end
        end
    end
    if best then
        return Vector3.new(best.Position.X, best.Position.Y - best.Size.Y * 0.5, best.Position.Z)
    end
    return nil
end

local function registerSurgeCell(inst)
    if inst and inst:IsA("Model") and inst.Name == GAME.SurgeCellModelName and not knownSurgeCells[inst] then
        knownSurgeCells[inst] = { tries = 0, lastTry = 0, born = os.clock() }
    end
end

function SurgeCell:OnEnable()
    knownSurgeCells = {}
    local eventFX = Workspace:FindFirstChild("EventFX")
    if eventFX then
        for _, inst in ipairs(eventFX:GetDescendants()) do
            if inst.Name == GAME.SurgeCellModelName and inst:IsA("Model") then
                registerSurgeCell(inst)
            end
        end
    end
    self:SetStatus("Monitorando Workspace.EventFX.EvCell", "idle")
end

function SurgeCell:OnDisable()
    knownSurgeCells = {}
end

function SurgeCell:Tick()
    local hrp = getCharacterParts()
    local target, info, targetPos, nearestDistance

    for model, data in pairs(knownSurgeCells) do
        if not model:IsDescendantOf(Workspace) then
            knownSurgeCells[model] = nil
        elseif data.tries >= SURGE_CELL_MAX_ATTEMPTS then
            knownSurgeCells[model] = nil
        elseif data.tries == 0 or os.clock() - data.lastTry >= SURGE_CELL_RETRY_DELAY then
            local pos = surgeCellCollectPosition(model)
            if pos then
                local distance = hrp and (hrp.Position - pos).Magnitude or math.huge
                if not nearestDistance or distance < nearestDistance then
                    target, info, targetPos, nearestDistance = model, data, pos, distance
                end
            end
        end
    end

    if not target then
        self:SetStatus("Aguardando célula Surge (" .. netState.surgeCellTotal .. " coletas registradas)", "idle")
        return
    end
    if moveLock then return end

    moveLock = true
    info.tries = info.tries + 1
    info.lastTry = os.clock()
    local cellStampBefore = netState.surgeCellStamp
    local candyBefore = getNum("Candy")
    local surgeUntilBefore = getNum("SurgeUntil")
    self:SetStatus("Indo até a célula Surge (tentativa " .. info.tries .. ")...", "work")

    local ok = teleportCollect(targetPos, function()
        local candyNow = getNum("Candy")
        local surgeUntilNow = getNum("SurgeUntil")
        local gotEvent = netState.surgeCellStamp > cellStampBefore
        local gotLocalReward = (candyBefore ~= nil and candyNow ~= nil and candyNow > candyBefore)
            or (surgeUntilBefore ~= nil and surgeUntilNow ~= nil and surgeUntilNow > surgeUntilBefore)
            or (candyBefore == nil and surgeUntilBefore == nil)
        return gotEvent and gotLocalReward
    end, SURGE_CELL_COLLECT_TIMEOUT)
    moveLock = false

    if ok then
        knownSurgeCells[target] = nil
        self.Count = self.Count + 1
        self:SetStatus("Célula Surge coletada (" .. self.Count .. ")", "ok")
    elseif not target:IsDescendantOf(Workspace) then
        knownSurgeCells[target] = nil
        self:SetStatus("Célula sumiu sem confirmação local", "warn")
    elseif info.tries >= SURGE_CELL_MAX_ATTEMPTS then
        knownSurgeCells[target] = nil
        self:SetStatus("Sem confirmação da célula; ignorada", "err")
    else
        self:SetStatus("Sem confirmação; tentando novamente", "warn")
    end
end

---------------------------------------------------------------------
-- 4) AUTO COLLECT AIRDROP (Ev Live/Got + posição L + teleporte por proximidade)
---------------------------------------------------------------------
local Airdrop = newFeature({
    Id = "airdrop", Name = "Auto Collect Airdrop", Category = "Coleta", Interval = 0.25,
})

local AIRDROP_MAX_ATTEMPTS = 2
local AIRDROP_RETRY_DELAY = 0.9
local AIRDROP_COLLECT_TIMEOUT = 1.4

function Airdrop:OnEnable()
    local run = netState.airdrop
    if run and #run.Crates > 0 then
        self:SetStatus("Airdrop detectado (" .. #run.Crates .. " caixas)", "ok")
    else
        self:SetStatus("Aguardando evento Airdrop", "idle")
    end
end

function Airdrop:Tick()
    local run = netState.airdrop
    if not run or #run.Crates == 0 then
        self:SetStatus("Aguardando evento Airdrop", "idle")
        return
    end

    local now = Workspace:GetServerTimeNow()
    local target, retryTarget, nextDropAt
    local pending, completed = 0, 0

    for _, crate in ipairs(run.Crates) do
        if crate.Got or crate.Finished then
            completed = completed + 1
        elseif crate.Tries >= AIRDROP_MAX_ATTEMPTS then
            crate.Finished = true
            completed = completed + 1
        else
            pending = pending + 1
            if crate.AvailableAt > 0 and now < crate.AvailableAt then
                if not nextDropAt or crate.AvailableAt < nextDropAt then
                    nextDropAt = crate.AvailableAt
                end
            elseif crate.Tries == 0 then
                -- Prioriza a primeira visita a cada caixa para acompanhar a sequência do avião.
                target = crate
                break
            elseif os.clock() - crate.LastTry >= AIRDROP_RETRY_DELAY and not retryTarget then
                retryTarget = crate
            end
        end
    end

    -- Só repete uma caixa quando não houver outra nova para cair em breve.
    if not target and retryTarget and (not nextDropAt or nextDropAt - now > AIRDROP_COLLECT_TIMEOUT) then
        target = retryTarget
    end

    if not target then
        if pending == 0 then
            self:SetStatus("Airdrop finalizado (" .. completed .. "/" .. #run.Crates .. ")", "idle")
        elseif nextDropAt then
            self:SetStatus("Próxima caixa em " .. string.format("%.1fs", math.max(0, nextDropAt - now)), "idle")
        else
            self:SetStatus("Aguardando caixas do Airdrop", "idle")
        end
        return
    end

    if moveLock then return end
    moveLock = true
    target.Tries = target.Tries + 1
    target.LastTry = os.clock()
    local kind = target.Golden and "dourada" or "normal"
    self:SetStatus("Indo para caixa " .. tostring(target.Id) .. " (" .. kind .. ")...", "work")

    local ok = teleportCollect(target.Pos, function()
        return target.Got
    end, AIRDROP_COLLECT_TIMEOUT)
    moveLock = false

    if target.Got then
        target.Finished = true
        if target.GotByLocalPlayer then
            self.Count = self.Count + 1
            self:SetStatus("Airdrop " .. tostring(target.Id) .. " coletado (" .. self.Count .. ")", "ok")
        else
            self:SetStatus("Caixa " .. tostring(target.Id) .. " já coletada por " .. tostring(target.GotBy or "outro jogador"), "warn")
        end
    elseif not ok and target.Tries >= AIRDROP_MAX_ATTEMPTS then
        target.Finished = true
        self:SetStatus("Sem confirmação na caixa " .. tostring(target.Id) .. "; pulando", "err")
    else
        self:SetStatus("Sem confirmação na caixa " .. tostring(target.Id) .. "; nova tentativa", "warn")
    end
end

---------------------------------------------------------------------
-- 5) AUTO SPIN (RemoteFunction Action:InvokeServer("Spin"))
---------------------------------------------------------------------
local Spin = newFeature({
    Id = "spin", Name = "Auto Spin (Roda da Sorte)", Category = "Progresso", Interval = 1.0,
})

local spinRemote = nil
local spinRemoteCheckedAt = 0
local spinInvokeBusy = false

local function getSpinRemote()
    if spinRemote and spinRemote.Parent then
        return spinRemote
    end

    -- Procura exatamente o caminho informado pelo desenvolvedor.
    local remotes = ReplicatedStorage:FindFirstChild("Remotes")
    local action = remotes and remotes:FindFirstChild("Action")
    if action and action:IsA("RemoteFunction") then
        spinRemote = action
        return spinRemote
    end

    -- Evita procurar a cada frame se o objeto ainda não foi replicado.
    if os.clock() - spinRemoteCheckedAt >= 2 then
        spinRemoteCheckedAt = os.clock()
        task.spawn(function()
            local ok, result = pcall(function()
                local folder = ReplicatedStorage:WaitForChild("Remotes", 5)
                if not folder then return nil end
                return folder:WaitForChild("Action", 5)
            end)
            if ok and result and result:IsA("RemoteFunction") then
                spinRemote = result
            end
        end)
    end
    return nil
end

function Spin:Tick()
    local nextTime = getNum("WheelNext")
    local spins = getNum("WheelSpins")
    local now = Workspace:GetServerTimeNow()

    -- WheelNext representa o fim da recarga gratuita; WheelSpins representa
    -- giros acumulados. Qualquer uma das condições libera uma tentativa.
    local ready = (nextTime ~= nil and now >= nextTime)
        or (spins ~= nil and spins > 0)

    if not ready then
        if nextTime ~= nil then
            self:SetStatus("Recarga: " .. fmtDuration(nextTime - now), "idle")
        else
            self:SetStatus("Aguardando WheelNext/WheelSpins", "idle")
        end
        return
    end

    if spinInvokeBusy then
        self:SetStatus("Aguardando resposta do servidor...", "work")
        return
    end

    if os.clock() < self.RetryAt then
        self:SetStatus("Nova tentativa em " .. fmtDuration(self.RetryAt - os.clock()), "warn")
        return
    end

    local remote = getSpinRemote()
    if not remote then
        self:SetStatus("Aguardando Remotes.Action...", "warn")
        return
    end

    local beforeNext = nextTime
    local beforeSpins = spins
    spinInvokeBusy = true
    self:SetStatus("Disponível; solicitando giro...", "work")

    -- InvokeServer é síncrono; pcall captura erros sem encerrar o helper.
    local callOk, result = pcall(function()
        return remote:InvokeServer("Spin")
    end)
    spinInvokeBusy = false

    if not callOk then
        self.Fails = self.Fails + 1
        self.RetryAt = os.clock() + math.min(15, 2 + self.Fails * 2)
        self:SetStatus("Falha no Spin: " .. tostring(result), "err")
        return
    end

    -- Não presume sucesso apenas porque InvokeServer retornou. Confere se
    -- o cooldown ou a quantidade de giros realmente mudou no estado replicado.
    local changed = waitUntil(function()
        local currentNext = getNum("WheelNext")
        local currentSpins = getNum("WheelSpins")
        return currentNext ~= beforeNext or currentSpins ~= beforeSpins
    end, CONFIG.SpinTimeout, 0.15)

    if changed then
        self.Fails = 0
        self.Count = self.Count + 1
        self:SetStatus("Giro confirmado (" .. self.Count .. "x); aguardando recarga", "ok")
    else
        -- Se o servidor não atualizou os atributos, não dispara em sequência.
        self.RetryAt = os.clock() + 5
        self:SetStatus("Solicitação enviada; aguardando atualização de WheelNext/WheelSpins", "warn")
    end
end

-- 6) AUTO REBIRTH (RemoteFunction Action:InvokeServer("Rebirth"))
---------------------------------------------------------------------
local Rebirth = newFeature({
    Id = "rebirth", Name = "Auto Rebirth", Category = "Progresso", Interval = 2,
})

local rebirthInvokeBusy = false

function Rebirth:Tick()
    if LocalPlayer:GetAttribute("Loaded") == false then
        self:SetStatus("Aguardando o jogo carregar", "idle")
        return
    end

    local cash, cost = getNum("Cash"), getNum("RebirthCost")
    if cash == nil or cost == nil then
        self:SetStatus("Aguardando Cash/RebirthCost", "idle")
        return
    end

    if cash < cost then
        self:SetStatus("Aguardando Cash >= RebirthCost", "idle")
        return
    end

    if rebirthInvokeBusy then
        self:SetStatus("Aguardando resposta do servidor...", "work")
        return
    end

    if os.clock() < self.RetryAt then
        self:SetStatus("Nova tentativa em " .. fmtDuration(self.RetryAt - os.clock()), "warn")
        return
    end

    local remote = getSpinRemote()
    if not remote then
        self:SetStatus("Aguardando ReplicatedStorage.Remotes.Action...", "warn")
        return
    end

    local beforeRebirths = getNum("Rebirths")
    local beforeCash = cash
    local beforeCost = cost

    rebirthInvokeBusy = true
    self:SetStatus("Requisito atendido; solicitando Rebirth...", "work")

    -- Chamada direta informada pelo usuário, no mesmo RemoteFunction do Spin.
    local callOk, result = pcall(function()
        return remote:InvokeServer("Rebirth")
    end)
    rebirthInvokeBusy = false

    if not callOk then
        self.Fails = self.Fails + 1
        self.RetryAt = os.clock() + math.min(20, 3 + self.Fails * 3)
        self:SetStatus("Falha no Rebirth: " .. tostring(result), "err")
        return
    end

    -- Confirma pelo aumento de Rebirths; como alternativa, verifica a mudança
    -- conjunta de Cash e RebirthCost, caso o jogo não replique Rebirths.
    local changed = waitUntil(function()
        local rebirthsNow = getNum("Rebirths")
        if beforeRebirths ~= nil and rebirthsNow ~= nil and rebirthsNow > beforeRebirths then
            return true
        end

        local cashNow, costNow = getNum("Cash"), getNum("RebirthCost")
        return beforeCash ~= nil and beforeCost ~= nil
            and cashNow ~= nil and costNow ~= nil
            and cashNow < beforeCash and costNow ~= beforeCost
    end, CONFIG.RebirthTimeout, 0.15)

    if changed then
        self.Fails = 0
        self.Count = self.Count + 1
        self:SetStatus("Rebirth confirmado (" .. self.Count .. "x)", "ok")
    else
        self.RetryAt = os.clock() + 6
        if type(result) == "table" and result.msg then
            self:SetStatus("Rebirth não confirmado: " .. tostring(result.msg), "warn")
        else
            self:SetStatus("Solicitação enviada; aguardando confirmação do servidor", "warn")
        end
    end
end


---------------------------------------------------------------------
-- 7) AUTO BUY (teleporte contínuo para Pads verdes do próprio Tycoon)
-- A posição do Tycoon é resolvida pelo atributo OwnerId do jogador local.
-- A elegibilidade é lida da cor do próprio BasePart "Pad".
---------------------------------------------------------------------
local AutoBuy = newFeature({
    Id = "auto_buy", Name = "Auto Buy", Category = "Progresso", Interval = 0.5,
})

local AUTO_BUY_GREEN = Color3.fromRGB(76, 190, 92)
local AUTO_BUY_COLOR_TOLERANCE = 24
local AUTO_BUY_CONFIRM_TIMEOUT = 5
local AUTO_BUY_HEIGHT = 2.5
local autoBuyOrigin = nil
local autoBuyBusy = false
local autoBuyTriedAt = {}
local autoBuyConfirmed = {}

local function autoBuyIsGreen(part)
    if not part or not part:IsA("BasePart") then return false end
    local c = part.Color
    return math.abs(c.R - AUTO_BUY_GREEN.R) * 255 <= AUTO_BUY_COLOR_TOLERANCE
        and math.abs(c.G - AUTO_BUY_GREEN.G) * 255 <= AUTO_BUY_COLOR_TOLERANCE
        and math.abs(c.B - AUTO_BUY_GREEN.B) * 255 <= AUTO_BUY_COLOR_TOLERANCE
end

local function autoBuyGetOwnedPlot()
    local tycoons = Workspace:FindFirstChild("Tycoons")
    if not tycoons then return nil end

    for _, plot in ipairs(tycoons:GetChildren()) do
        local ownerId = plot:GetAttribute("OwnerId")
        if ownerId ~= nil and tonumber(ownerId) == LocalPlayer.UserId then
            return plot
        end
    end
    return nil
end

local function autoBuyGetGreenPads()
    local plot = autoBuyGetOwnedPlot()
    local padsFolder = plot and plot:FindFirstChild("Pads")
    if not padsFolder then return {}, "Aguardando seu Tycoon/Pads" end

    local available = {}
    for _, pad in ipairs(padsFolder:GetChildren()) do
        if pad:IsA("BasePart")
            and pad:GetAttribute("Item") ~= nil
            and tostring(pad:GetAttribute("Item")) ~= ""
            and autoBuyIsGreen(pad) then

            local itemId = tostring(pad:GetAttribute("Item"))
            local lastTry = autoBuyTriedAt[itemId] or 0
            if not autoBuyConfirmed[itemId] and os.clock() - lastTry >= 2 then
                available[#available + 1] = {
                    Part = pad,
                    Id = itemId,
                    Name = itemId,
                }
            end
        end
    end
    return available, nil
end

function AutoBuy:OnEnable()
    autoBuyTriedAt = {}
    autoBuyConfirmed = {}
    autoBuyBusy = false
    local root = getCharacterParts()
    autoBuyOrigin = root and root.CFrame or nil
    self:SetStatus("Procurando Pads verdes no seu Tycoon...", "work")
end

function AutoBuy:OnDisable()
    autoBuyBusy = false
    local root = getCharacterParts()
    if root and autoBuyOrigin then
        root.CFrame = autoBuyOrigin
        root.AssemblyLinearVelocity = Vector3.zero
    end
    autoBuyOrigin = nil
    self:SetStatus("Desligado; posição inicial restaurada", "idle")
end

function AutoBuy:Tick()
    if autoBuyBusy then return end
    if LocalPlayer:GetAttribute("Loaded") == false then
        self:SetStatus("Aguardando o jogo carregar", "idle")
        return
    end

    local root = getCharacterParts()
    if not root then
        self:SetStatus("Aguardando personagem", "warn")
        return
    end
    if not autoBuyOrigin then autoBuyOrigin = root.CFrame end

    local pads, reason = autoBuyGetGreenPads()
    if reason then
        self:SetStatus(reason, "warn")
        return
    end

    if #pads == 0 then
        -- Continua ligado e monitorando; se um Pad ficar verde depois, irá até ele.
        if autoBuyOrigin and (root.Position - autoBuyOrigin.Position).Magnitude > 5 then
            root.CFrame = autoBuyOrigin
            root.AssemblyLinearVelocity = Vector3.zero
        end
        self:SetStatus("Nenhum Pad verde; monitorando disponibilidade...", "idle")
        return
    end

    -- Escolhe o primeiro Pad elegível encontrado nesta varredura.
    local target = pads[1]
    if not target.Part or not target.Part.Parent or not autoBuyIsGreen(target.Part) then
        return
    end

    autoBuyBusy = true
    local beforeStamp = netState.boughtStamp
    self:SetStatus("Indo ao Pad " .. target.Id .. "...", "work")

    root.CFrame = target.Part.CFrame + Vector3.new(0, AUTO_BUY_HEIGHT, 0)
    root.AssemblyLinearVelocity = Vector3.zero

    local confirmed = waitUntil(function()
        return netState.boughtStamp > beforeStamp
            and netState.lastBoughtId == target.Id
    end, AUTO_BUY_CONFIRM_TIMEOUT, 0.1)

    if confirmed then
        autoBuyTriedAt[target.Id] = os.clock()
        autoBuyConfirmed[target.Id] = true
        self.Count = self.Count + 1
        self:SetStatus("Compra confirmada: " .. target.Id .. " (" .. self.Count .. ")", "ok")
    else
        -- Evita ficar preso repetindo teleporte para um Pad que não confirmou.
        autoBuyTriedAt[target.Id] = os.clock()
        self:SetStatus("Sem confirmação para " .. target.Id .. "; verificando outros Pads", "warn")
    end

    autoBuyBusy = false
end

---------------------------------------------------------------------
-- 8) AUTO Q (só pressiona quando o Overdrive está disponível)
---------------------------------------------------------------------
local AutoQ = newFeature({
    Id = "auto_q", Name = "Auto Click Q", Category = "Automação", Interval = 0.03,
})

local function getServerNow()
    local ok, value = pcall(function()
        return Workspace:GetServerTimeNow()
    end)
    if ok and type(value) == "number" then return value end
    -- Fallback: timestamps do jogo são Unix; os.time() tem precisão de 1 segundo.
    return os.time()
end

local function getOverdriveWindow()
    local attrUntil = getNum("OdUntil")
    local attrReady = getNum("OdReady")

    -- Usa também os eventos oficiais recebidos, caso os atributos ainda não tenham replicado.
    local untilSource = attrUntil or netState.overdriveUntil
    local readySource = attrReady or netState.overdriveReady

    -- Exige os dois marcadores; não presume disponibilidade com dados incompletos.
    if untilSource == nil or readySource == nil then
        return nil, nil
    end

    -- Mantém o timestamp mais recente entre atributo e evento.
    local untilAt = math.max(attrUntil or 0, netState.overdriveUntil or 0)
    local readyAt = math.max(attrReady or 0, netState.overdriveReady or 0)
    return untilAt, readyAt
end

function AutoQ:OnDisable()
    -- Garante que a tecla seja solta ao desligar a função.
    if VirtualInputManager then
        pcall(function()
            VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Q, false, game)
        end)
    end
end

function AutoQ:Tick()
    if not VirtualInputManager then
        self:SetStatus("VirtualInputManager indisponível neste executor", "err")
        return
    end

    local untilAt, readyAt = getOverdriveWindow()
    if untilAt == nil or readyAt == nil then
        self:SetStatus("Aguardando dados do Overdrive (OdUntil/OdReady)", "warn")
        return
    end

    local now = getServerNow()
    local activeLeft = untilAt - now
    local cooldownLeft = readyAt - now

    if activeLeft > 0 then
        self:SetStatus("Overdrive ativo — Q pausado (" .. math.ceil(activeLeft) .. "s)", "warn")
        return
    end

    if cooldownLeft > 0 then
        self:SetStatus("Overdrive em recarga — Q pausado (" .. math.ceil(cooldownLeft) .. "s)", "warn")
        return
    end

    local ok = pcall(function()
        VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.Q, false, game)
        task.wait(0.02)
        VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Q, false, game)
    end)

    if ok then
        self.Count = self.Count + 1
        local charge = getNum("OdCharge")
        local chargeText = charge ~= nil and (" | carga " .. tostring(charge)) or ""
        self:SetStatus("Overdrive disponível — pressionando Q (" .. self.Count .. "x)" .. chargeText, "work")
    else
        self:SetStatus("Falha ao enviar a tecla Q", "err")
    end
end

---------------------------------------------------------------------
-- 9) ANTI AFK (Infinite Yield: evento Idled + clique virtual)
---------------------------------------------------------------------
local AntiAFK = newFeature({
    Id = "anti_afk", Name = "Anti AFK (Idled)", Category = "Player", Interval = 1,
})
function AntiAFK:OnEnable()
    if not LocalPlayer.Idled or not Compat.VirtualInput then
        self:SetStatus("Idled/VirtualInputManager indisponível", "err")
        return
    end
    local vim = Compat.VirtualInput
    self:TrackConnection(LocalPlayer.Idled:Connect(function()
        if self.Enabled then
            pcall(function()
                vim:SendMouseButtonEvent(0, 0, 0, true, game, 0)
                vim:SendMouseButtonEvent(0, 0, 0, false, game, 0)
            end)
        end
    end))
    self:SetStatus("Ativo: clique virtual ao detectar inatividade", "ok")
end
function AntiAFK:OnDisable()
    self:SetStatus("Monitoramento Idled encerrado", "idle")
end
function AntiAFK:Tick()
    if #self.Connections > 0 then self:SetStatus("Monitorando evento Idled", "ok") end
end

---------------------------------------------------------------------
-- 9A) MOVIMENTAÇÃO
---------------------------------------------------------------------
---------------------------------------------------------------------
-- 9A.1) PULO INFINITO
---------------------------------------------------------------------
local InfiniteJump = newFeature({
    Id="infinite_jump", Name="Pulo infinito", Category="Player", Interval=1,
})
InfiniteJump.Debounce = false
function InfiniteJump:OnEnable()
    self.Debounce = false
    self:TrackConnection(UserInputService.JumpRequest:Connect(function()
        if not self.Enabled or self.Debounce then return end
        self.Debounce = true

        local character = LocalPlayer.Character
        local humanoid = character and character:FindFirstChildWhichIsA("Humanoid")
        if humanoid and humanoid.Health > 0 then
            pcall(function()
                humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
            end)
        end

        task.wait()
        self.Debounce = false
    end))
    self:SetStatus("Ativo — pulo disponível no ar", "ok")
end
function InfiniteJump:Tick()
    if #self.Connections > 0 then
        self:SetStatus("Ativo — pressione pular para saltar no ar", "ok")
    end
end
function InfiniteJump:OnDisable()
    self.Debounce = false
    self:SetStatus("Pulo infinito desativado", "idle")
end

local Fly = newFeature({Id="fly", Name="Fly", Category="Player", Interval=0.05})
local flyKeys = {W=false,A=false,S=false,D=false,Up=false,Down=false}
local function flyDirection()
    local camera = Workspace.CurrentCamera
    if not camera then return Vector3.zero end
    local v = Vector3.zero
    if flyKeys.W then v += camera.CFrame.LookVector end
    if flyKeys.S then v -= camera.CFrame.LookVector end
    if flyKeys.D then v += camera.CFrame.RightVector end
    if flyKeys.A then v -= camera.CFrame.RightVector end
    if flyKeys.Up then v += Vector3.yAxis end
    if flyKeys.Down then v -= Vector3.yAxis end
    return v.Magnitude > 0 and v.Unit or Vector3.zero
end
function Fly:OnEnable()
    local root, humanoid = getCharacterParts()
    if not root or not humanoid then self:SetStatus("Personagem indisponível", "warn"); return end
    local gyro = Instance.new("BodyGyro")
    gyro.Name, gyro.P, gyro.MaxTorque, gyro.Parent = "TycoonHelperFlyGyro", 9e4, Vector3.new(9e9,9e9,9e9), root
    local velocity = Instance.new("BodyVelocity")
    velocity.Name, velocity.MaxForce, velocity.Velocity, velocity.Parent =
        "TycoonHelperFlyVelocity", Vector3.new(9e9,9e9,9e9), Vector3.zero, root
    self.Gyro, self.Velocity, self.Root = gyro, velocity, root
    local keyMap = {
        [Enum.KeyCode.W]="W", [Enum.KeyCode.A]="A", [Enum.KeyCode.S]="S",
        [Enum.KeyCode.D]="D", [Enum.KeyCode.Space]="Up", [Enum.KeyCode.LeftControl]="Down",
    }
    self:TrackConnection(UserInputService.InputBegan:Connect(function(input, processed)
        if not processed and keyMap[input.KeyCode] then flyKeys[keyMap[input.KeyCode]]=true end
    end))
    self:TrackConnection(UserInputService.InputEnded:Connect(function(input)
        if keyMap[input.KeyCode] then flyKeys[keyMap[input.KeyCode]]=false end
    end))
    self:TrackCleanup(function()
        table.clear(flyKeys)
        pcall(function() velocity:Destroy() end)
        pcall(function() gyro:Destroy() end)
        if humanoid.Parent then humanoid.PlatformStand=false end
    end)
    humanoid.PlatformStand = true
    self:SetStatus("Fly ativo | WASD + Espaço/Ctrl", "ok")
end
function Fly:OnDisable()
    local _, humanoid = getCharacterParts()
    if humanoid then humanoid.PlatformStand=false end
    self.Gyro, self.Velocity, self.Root = nil, nil, nil
end
function Fly:Tick()
    if not self.Root or not self.Root.Parent or not self.Velocity then
        self:SetStatus("Aguardando personagem", "warn"); return
    end
    if Workspace.CurrentCamera and self.Gyro then self.Gyro.CFrame=Workspace.CurrentCamera.CFrame end
    self.Velocity.Velocity=flyDirection()*60
end

local Noclip = newFeature({Id="noclip", Name="Noclip", Category="Player", Interval=0.05})
function Noclip:OnEnable() self.Original={} end
function Noclip:Tick()
    local character=LocalPlayer.Character
    if not character then return end
    for _,part in ipairs(character:GetDescendants()) do
        if part:IsA("BasePart") then
            if self.Original[part]==nil then self.Original[part]=part.CanCollide end
            part.CanCollide=false
        end
    end
end
function Noclip:OnDisable()
    for part,old in pairs(self.Original or {}) do
        if part and part.Parent then pcall(function() part.CanCollide=old end) end
    end
    self.Original={}
end

local Speed = newFeature({Id="walk_speed", Name="WalkSpeed", Category="Player", Interval=0.25})
Speed.Value = 32
function Speed:OnEnable()
    local _,hum=getCharacterParts()
    if hum then self.Old=hum.WalkSpeed; hum.WalkSpeed=self.Value end
end
function Speed:Tick()
    local _,hum=getCharacterParts()
    if hum then hum.WalkSpeed=self.Value end
end
function Speed:OnDisable()
    local _,hum=getCharacterParts()
    if hum then hum.WalkSpeed=self.Old or 16 end
end

local Jump = newFeature({Id="jump_power", Name="Força de pulo", Category="Player", Interval=0.25})
Jump.Value = 75
function Jump:OnEnable()
    local _,hum=getCharacterParts()
    if hum then self.Old=hum.JumpPower; self.OldUseJumpPower=hum.UseJumpPower; hum.UseJumpPower=true; hum.JumpPower=self.Value end
end
function Jump:Tick()
    local _,hum=getCharacterParts()
    if hum then hum.UseJumpPower=true; hum.JumpPower=self.Value end
end
function Jump:OnDisable()
    local _,hum=getCharacterParts()
    if hum then
        hum.JumpPower=self.Old or 50
        if self.OldUseJumpPower ~= nil then hum.UseJumpPower=self.OldUseJumpPower end
    end
end


local TeleportPlayer = newFeature({
    Id="teleport_player", Name="Teleport to Player", Category="Player",
    Interval=0.5, InputPlaceholder="Players",
})
function TeleportPlayer:Tick()
    local selection = self.PendingTarget
    if not selection or selection == "" then return end
    self.PendingTarget = nil
    local target
    if typeof(selection) == "Instance" and selection:IsA("Player") then
        target = selection
    else
        local query = tostring(selection):lower()
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LocalPlayer and (p.Name:lower():find(query, 1, true)
                or p.DisplayName:lower():find(query, 1, true)) then
                target = p
                break
            end
        end
    end
    local targetRoot = target and target.Character and target.Character:FindFirstChild("HumanoidRootPart")
    local root = getCharacterParts()
    if target and target ~= LocalPlayer and targetRoot and root then
        root.CFrame = targetRoot.CFrame * CFrame.new(0, 0, 3)
        self:SetStatus("Teleportado até " .. target.Name, "ok")
    else
        self:SetStatus("Jogador saiu ou está sem personagem", "warn")
    end
    setEnabled(self, false)
end

---------------------------------------------------------------------
-- 9B) SERVIDOR
---------------------------------------------------------------------
local TeleportService=game:GetService("TeleportService")
local HttpService=game:GetService("HttpService")
local Rejoin = newFeature({Id="server_rejoin", Name="Rejoin servidor atual", Category="Servidor", Interval=1})
function Rejoin:Tick()
    self:SetStatus("Reconectando ao mesmo servidor...", "work")
    local ok,err=pcall(function()
        TeleportService:TeleportToPlaceInstance(game.PlaceId,game.JobId,LocalPlayer)
    end)
    if not ok then self:SetStatus("Rejoin falhou: "..tostring(err),"err") end
    setEnabled(self,false)
end

local ServerHop = newFeature({Id="server_hop", Name="Server Hop", Category="Servidor", Interval=1})
function ServerHop:Tick()
    self:SetStatus("Buscando servidor público com vagas...", "work")
    local cursor, chosen = "", nil
    for _=1,4 do
        local url="https://games.roblox.com/v1/games/"..game.PlaceId.."/servers/Public?sortOrder=Asc&limit=100"
        if cursor~="" then url=url.."&cursor="..HttpService:UrlEncode(cursor) end
        local response,err=safeRequest({Url=url,Method="GET"})
        if not response then self:SetStatus("HTTP indisponível: "..tostring(err),"err"); setEnabled(self,false); return end
        local ok,data=pcall(function()
            return HttpService:JSONDecode(response.Body or response.body or "")
        end)
        if not ok or type(data)~="table" then
            self:SetStatus("Resposta inválida da lista de servidores","err"); setEnabled(self,false); return
        end
        for _,server in ipairs(data.data or {}) do
            if server.id and server.id~=game.JobId and (server.playing or 0)<(server.maxPlayers or 0) then
                chosen=server.id; break
            end
        end
        if chosen then break end
        cursor=data.nextPageCursor or ""
        if cursor=="" then break end
    end
    if not chosen then self:SetStatus("Nenhum servidor público com vaga encontrado","warn"); setEnabled(self,false); return end
    local ok,err=pcall(function()
        TeleportService:TeleportToPlaceInstance(game.PlaceId,chosen,LocalPlayer)
    end)
    if not ok then self:SetStatus("Server Hop falhou: "..tostring(err),"err") end
    setEnabled(self,false)
end

local ServerInfo = newFeature({Id="server_info", Name="Informações do servidor", Category="Servidor", Interval=1})
function ServerInfo:Tick()
    local ping="N/D"
    pcall(function()
        ping=tostring(math.floor(game:GetService("Stats").Network.ServerStatsItem["Data Ping"]:GetValue())).." ms"
    end)
    self:SetStatus(string.format("Players: %d/%d | PlaceId: %s | JobId: %s | Ping: %s",
        #Players:GetPlayers(),Players.MaxPlayers,tostring(game.PlaceId),
        tostring(game.JobId):sub(1,12),ping),"ok")
end

---------------------------------------------------------------------
-- 10) AUTO CLAIM DOS DOIS OBBYS (DIAMOND / GOLDEN DROPPER)
-- Cada Toast, confirmação e ponto de coleta é tratado separadamente.
-- PowerNext/ObbyNext são lidos do Player local resolvido por UserId,
-- nunca de um nome de jogador fixo.
---------------------------------------------------------------------
local OBBY_WAIT_TIMEOUT = 15

-- Resolve sempre o Player que executou esta cópia do script.
-- Usa UserId como identidade; não depende de nomes como "Geeh_OOO".
local function getExecutingPlayer()
    local currentLocalPlayer = Players.LocalPlayer
    if currentLocalPlayer and currentLocalPlayer.UserId then
        local playerByUserId = Players:GetPlayerByUserId(currentLocalPlayer.UserId)
        if playerByUserId then
            return playerByUserId
        end
        return currentLocalPlayer
    end
    return nil
end

local function readObbyCooldownAttribute(attributeName)
    local executingPlayer = getExecutingPlayer()
    if not executingPlayer then
        return nil, "Player local ainda não identificado"
    end

    local value = executingPlayer:GetAttribute(attributeName)
    if value == nil then
        return nil, "Atributo " .. attributeName .. " ainda não existe em Players." .. executingPlayer.Name
    end

    local numericValue = tonumber(value)
    -- Alguns estados do jogo usam 0 para indicar que o Obby já está disponível.
    -- Portanto, zero também é um timestamp válido (pronto imediatamente).
    if not numericValue or numericValue < 0 then
        return nil, "Atributo " .. attributeName .. " inválido em Players." .. executingPlayer.Name
    end

    return numericValue, nil
end

local function resolveObbyReward(config)
    local node = Workspace
    for _, childName in ipairs(config.RewardPath) do
        node = node:FindFirstChild(childName)
        if not node then
            return nil
        end
    end
    if node:IsA("BasePart") then
        return node
    end
    return nil
end

local function createObbyCollector(config)
    local feature = newFeature({
        Id = config.Id, Name = config.Name, Category = "Progresso", Interval = 1,
    })

    function feature:OnEnable()
        self.CancelRequested = false
        if not netState.obbyReadyAt[config.Key] then
            self:SetStatus("Aguardando contagem do servidor", "warn")
        else
            self:SetStatus("Monitorando " .. config.DisplayName, "idle")
        end
    end

    function feature:OnDisable()
        self.CancelRequested = true
    end

    function feature:Tick()
        if self.Busy then return end

        -- Os timestamps replicados pelo servidor são a fonte principal de disponibilidade:
        -- PowerNext = Power Plant / Diamond Dropper
        -- ObbyNext   = Obby / Golden Dropper
        -- Isso também funciona se o Toast ocorreu antes de o helper ser iniciado.
        local readyAt = netState.obbyReadyAt[config.Key]
        local attributeName = config.Key == "diamond" and "PowerNext" or "ObbyNext"

        -- Lê o atributo do jogador que está executando o script nesta sessão.
        -- tonumber também aceita atributos replicados como texto numérico.
        local attributeNext, attributeError = readObbyCooldownAttribute(attributeName)
        if attributeNext then
            readyAt = attributeNext
            netState.obbyReadyAt[config.Key] = attributeNext
        end

        if not readyAt then
            local executingPlayer = getExecutingPlayer()
            local playerLabel = executingPlayer and executingPlayer.Name or "jogador local"
            self:SetStatus("Aguardando " .. attributeName .. " de " .. playerLabel .. " ou Toast", "warn")
            return
        end

        local remaining = readyAt - Workspace:GetServerTimeNow()
        if remaining > 0 then
            self:SetStatus(config.DisplayName .. " disponível em " .. fmtDuration(remaining), "idle")
            return
        end
        if moveLock then
            self:SetStatus("Aguardando outro teleporte terminar", "warn")
            return
        end

        local root = getCharacterParts()
        if not root then
            self:SetStatus("Aguardando personagem válido", "warn")
            return
        end

        self.Busy = true
        self.CancelRequested = false
        moveLock = true
        local rewardPart = resolveObbyReward(config)
        if not rewardPart then
            moveLock = false
            self.Busy = false
            self:SetStatus("Não encontrei a peça Reward no Workspace", "err")
            return
        end

        local original = root.CFrame
        local beforeStamp = netState.obbyClaimStamp[config.Key]
        local readyAtBefore = readyAt
        local target = rewardPart.CFrame + Vector3.new(0, CONFIG.TeleportHeightOffset, 0)
        self:SetStatus(config.DisplayName .. " pronto; indo até Reward...", "work")

        local function restore()
            local current = getCharacterParts()
            if current then
                current.CFrame = original
                current.AssemblyLinearVelocity = Vector3.zero
            end
        end

        local success = false
        local ok, err = pcall(function()
            root.CFrame = target
            root.AssemblyLinearVelocity = Vector3.zero
            local deadline = os.clock() + OBBY_WAIT_TIMEOUT
            while alive and self.Enabled and not self.CancelRequested and os.clock() < deadline do
                if netState.obbyClaimStamp[config.Key] > beforeStamp then
                    success = true
                    break
                end
                task.wait(0.1)
            end
        end)

        restore()
        moveLock = false
        self.Busy = false

        if not ok then
            self:SetStatus("Erro durante a coleta: " .. tostring(err):sub(1, 55), "err")
        elseif success then
            self.Count = self.Count + 1
            local title = netState.obbyLastTitle[config.Key] or "Obby concluído"
            self:SetStatus("Confirmado: " .. title .. " (" .. self.Count .. ")", "ok")
            if netState.obbyReadyAt[config.Key] == readyAtBefore then
                netState.obbyReadyAt[config.Key] = nil
            end
        elseif not self.Enabled or self.CancelRequested then
            self:SetStatus("Desligado; retorno à posição original realizado", "warn")
        else
            self:SetStatus("Sem confirmação de " .. config.DisplayName .. "; retornei à origem", "warn")
            netState.obbyReadyAt[config.Key] = Workspace:GetServerTimeNow() + 30
        end
    end

    return feature
end

-- Power Plant / Diamond Dropper
local ObbyDiamond = createObbyCollector({
    Id = "obby_diamond", Name = "Auto Claim Obby (Diamond Dropper)",
    Key = "diamond", DisplayName = "Power Plant / Diamond Dropper",
    RewardPath = {"World", "PowerPlant", "DiamondDropper", "Reward"},
})

-- Obby comum / Golden Dropper
local ObbyGolden = createObbyCollector({
    Id = "obby_golden", Name = "Auto Claim Obby (Golden Dropper)",
    Key = "golden", DisplayName = "Obby / Golden Dropper",
    RewardPath = {"World", "Obby", "GoldenDropper", "Reward"},
})

---------------------------------------------------------------------
-- Interface gráfica
---------------------------------------------------------------------
local gui

local COLORS = {
    window = Color3.fromRGB(22, 24, 31),
    header = Color3.fromRGB(34, 38, 50),
    row = Color3.fromRGB(34, 38, 50),
    accent = Color3.fromRGB(110, 168, 255),
    text = Color3.fromRGB(235, 238, 245),
    sub = Color3.fromRGB(150, 160, 180),
    on = Color3.fromRGB(64, 180, 110),
    off = Color3.fromRGB(72, 78, 98),
    kinds = {
        idle = Color3.fromRGB(150, 160, 180),
        ok = Color3.fromRGB(120, 210, 150),
        warn = Color3.fromRGB(240, 190, 90),
        err = Color3.fromRGB(240, 110, 110),
        work = Color3.fromRGB(130, 175, 255),
    },
}

local function corner(parent, radius)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, radius)
    c.Parent = parent
    return c
end

local savedLocationsLauncher

local function buildGui()
    gui = Instance.new("ScreenGui")
    gui.Name = "TycoonHelper"
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 999
    local ok = pcall(function() gui.Parent = (Compat.GetHui and Compat.GetHui()) or game:GetService("CoreGui") end)
    if not ok or not gui.Parent then gui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

    local main = Instance.new("Frame")
    main.Size = UDim2.fromOffset(340, 0)
    main.AutomaticSize = Enum.AutomaticSize.Y
    main.Position = UDim2.new(0, 24, 0, 80)
    main.BackgroundColor3 = COLORS.window
    main.BackgroundTransparency = 0.06
    main.BorderSizePixel = 0
    main.Parent = gui
    corner(main, 12)
    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(60, 66, 86)
    stroke.Transparency = 0.3
    stroke.Parent = main
    local mainLayout = Instance.new("UIListLayout")
    mainLayout.SortOrder = Enum.SortOrder.LayoutOrder
    mainLayout.Parent = main

    -- Cabeçalho (arrastável) com minimizar e fechar
    local header = Instance.new("Frame")
    header.LayoutOrder = 1
    header.Size = UDim2.new(1, 0, 0, 36)
    header.BackgroundColor3 = COLORS.header
    header.BorderSizePixel = 0
    header.Parent = main
    corner(header, 12)

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -80, 1, 0)
    title.Position = UDim2.fromOffset(12, 0)
    title.BackgroundTransparency = 1
    title.Text = "Tycoon with a twist"
    title.TextColor3 = COLORS.text
    title.Font = Enum.Font.GothamBold
    title.TextSize = 14
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = header

    local function headerButton(text, xOffset, color, callback)
        local b = Instance.new("TextButton")
        b.Size = UDim2.fromOffset(26, 24)
        b.Position = UDim2.new(1, xOffset, 0, 6)
        b.BackgroundColor3 = color
        b.BorderSizePixel = 0
        b.Text = text
        b.TextColor3 = COLORS.text
        b.Font = Enum.Font.GothamBold
        b.TextSize = 13
        b.Parent = header
        corner(b, 6)
        track(b.MouseButton1Click:Connect(callback))
        return b
    end

    local body = Instance.new("Frame")
    body.LayoutOrder = 2
    body.Size = UDim2.new(1, 0, 0, 0)
    body.AutomaticSize = Enum.AutomaticSize.Y
    body.BackgroundTransparency = 1
    body.Parent = main
    local bodyPadding = Instance.new("UIPadding")
    bodyPadding.PaddingTop = UDim.new(0, 8)
    bodyPadding.PaddingBottom = UDim.new(0, 10)
    bodyPadding.PaddingLeft = UDim.new(0, 8)
    bodyPadding.PaddingRight = UDim.new(0, 8)
    bodyPadding.Parent = body
    local bodyLayout = Instance.new("UIListLayout")
    bodyLayout.Padding = UDim.new(0, 6)
    bodyLayout.SortOrder = Enum.SortOrder.LayoutOrder
    bodyLayout.Parent = body

    -- minimizar/expandir (os controles somem, o script continua rodando)
    headerButton("–", -62, COLORS.off, function() body.Visible = not body.Visible end)
    headerButton("X", -32, Color3.fromRGB(170, 60, 60), function()
        if env.__TBOD_AUTO then env.__TBOD_AUTO.Destroy() end
    end)

    -- Arrastar
    local dragging, dragStart, startPos
    track(header.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging, dragStart, startPos = true, input.Position, main.Position
        end
    end))
    track(UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end))
    track(UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end))

    -- As categorias passam a funcionar como abas; cada aba mostra apenas seus próprios toggles.
    local rows = {}
    local order = 0
    local function nextOrder()
        order = order + 1
        return order
    end

    local categories, categoryOrder = {}, {}
    for _, f in ipairs(Features) do
        if not categories[f.Category] then
            categories[f.Category] = {}
            categoryOrder[#categoryOrder + 1] = f.Category
        end
        table.insert(categories[f.Category], f)
    end

    local tabBar = Instance.new("Frame")
    tabBar.LayoutOrder = nextOrder()
    tabBar.Size = UDim2.new(1, 0, 0, 30)
    tabBar.BackgroundTransparency = 1
    tabBar.Parent = body
    local tabLayout = Instance.new("UIListLayout")
    tabLayout.FillDirection = Enum.FillDirection.Horizontal
    tabLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
    tabLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    tabLayout.Padding = UDim.new(0, 4)
    tabLayout.SortOrder = Enum.SortOrder.LayoutOrder
    tabLayout.Parent = tabBar

    local pagesHolder = Instance.new("Frame")
    pagesHolder.LayoutOrder = nextOrder()
    pagesHolder.Size = UDim2.new(1, 0, 0, 0)
    pagesHolder.BackgroundTransparency = 1
    pagesHolder.ClipsDescendants = true
    pagesHolder.Parent = body

    local pages, tabButtons = {}, {}
    local function selectTab(categoryName)
        for name, page in pairs(pages) do
            page.Visible = (name == categoryName)
        end
        local selected = pages[categoryName]
        if selected then
            pagesHolder.Size = UDim2.new(1, 0, 0, selected.Size.Y.Offset)
        end
        for name, button in pairs(tabButtons) do
            local active = name == categoryName
            button.BackgroundColor3 = active and COLORS.accent or COLORS.off
            button.TextColor3 = COLORS.text
        end
    end

    for _, categoryName in ipairs(categoryOrder) do
        local featureList = categories[categoryName]
        local page = Instance.new("Frame")
        page.Name = "Page_" .. categoryName:gsub("%W", "")
        page.Position = UDim2.fromOffset(0, 0)
        local pageHeight = 18
        for _, feature in ipairs(featureList) do
            pageHeight = pageHeight + ((feature.Id == "walk_speed" or feature.Id == "jump_power") and 78 or (feature.Id == "teleport_player" and 48 or 66)) + 6
        end
        page.Size = UDim2.new(1, 0, 0, pageHeight)
        page.BackgroundTransparency = 1
        page.Visible = false
        page.Parent = pagesHolder
        pages[categoryName] = page

        local pageLayout = Instance.new("UIListLayout")
        pageLayout.Padding = UDim.new(0, 6)
        pageLayout.SortOrder = Enum.SortOrder.LayoutOrder
        pageLayout.Parent = page

        local label = Instance.new("TextLabel")
        label.LayoutOrder = nextOrder()
        label.Size = UDim2.new(1, 0, 0, 18)
        label.BackgroundTransparency = 1
        label.Text = string.upper(categoryName)
        label.TextColor3 = COLORS.accent
        label.Font = Enum.Font.GothamBold
        label.TextSize = 11
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.Parent = page

        for _, f in ipairs(featureList) do
            local row = Instance.new("Frame")
            row.LayoutOrder = nextOrder()
            local hasValueControl = (f.Id == "walk_speed" or f.Id == "jump_power")
            row.Size = UDim2.new(1, 0, 0, hasValueControl and 78 or (f.Id == "teleport_player" and 48 or 60))
            row.BackgroundColor3 = COLORS.row
            row.BorderSizePixel = 0
            row.Parent = page
            corner(row, 8)

            local nameLabel = Instance.new("TextLabel")
            nameLabel.Size = UDim2.new(1, (f.Id == "teleport_player") and -130 or -90, 0, 18)
            nameLabel.Position = UDim2.fromOffset(10, 6)
            nameLabel.BackgroundTransparency = 1
            nameLabel.Text = f.Name
            if hasValueControl then nameLabel.Size = UDim2.new(1, -90, 0, 16) end
            nameLabel.TextColor3 = COLORS.text
            nameLabel.Font = Enum.Font.GothamMedium
            nameLabel.TextSize = 13
            nameLabel.TextXAlignment = Enum.TextXAlignment.Left
            nameLabel.Parent = row

            local statusLabel = Instance.new("TextLabel")
            statusLabel.Size = UDim2.new(1, (f.Id == "teleport_player") and -130 or (hasValueControl and -90 or -90), 0, hasValueControl and 15 or 30)
            statusLabel.Position = UDim2.fromOffset(10, hasValueControl and 22 or 25)
            statusLabel.BackgroundTransparency = 1
            statusLabel.Text = f.Status
            statusLabel.TextColor3 = COLORS.kinds.idle
            statusLabel.Font = Enum.Font.Gotham
            statusLabel.TextSize = 11
            statusLabel.TextWrapped = true
            statusLabel.TextXAlignment = Enum.TextXAlignment.Left
            statusLabel.TextYAlignment = Enum.TextYAlignment.Top
            statusLabel.Parent = row

            local toggle
            if f.Id ~= "teleport_player" then
                toggle = Instance.new("TextButton")
                toggle.Size = UDim2.fromOffset(58, 28)
                toggle.Position = UDim2.new(1, -68, 0.5, -14)
                toggle.BackgroundColor3 = COLORS.off
                toggle.BorderSizePixel = 0
                toggle.Text = "OFF"
                toggle.TextColor3 = COLORS.text
                toggle.Font = Enum.Font.GothamBold
                toggle.TextSize = 12
                toggle.Parent = row
                corner(toggle, 14)
                track(toggle.MouseButton1Click:Connect(function()
                    setEnabled(f, not f.Enabled)
                end))
            end

            local valueBox, sliderTrack, sliderFill, sliderKnob
            if hasValueControl then
                valueBox = Instance.new("TextBox")
                valueBox.Size = UDim2.fromOffset(42, 22)
                valueBox.Position = UDim2.fromOffset(10, 49)
                valueBox.BackgroundColor3 = COLORS.off
                valueBox.BorderSizePixel = 0
                valueBox.Text = tostring(f.Value or 1)
                valueBox.TextColor3 = COLORS.text
                valueBox.Font = Enum.Font.GothamMedium
                valueBox.TextSize = 11
                valueBox.ClearTextOnFocus = false
                valueBox.Parent = row
                corner(valueBox, 5)

                sliderTrack = Instance.new("Frame")
                sliderTrack.Position = UDim2.new(0, 62, 0, 57)
                sliderTrack.Size = UDim2.new(1, -145, 0, 6)
                sliderTrack.BackgroundColor3 = COLORS.off
                sliderTrack.BorderSizePixel = 0
                sliderTrack.Parent = row
                corner(sliderTrack, 4)
                sliderFill = Instance.new("Frame")
                sliderFill.Size = UDim2.new(math.clamp((f.Value or 1) / 200, 0, 1), 0, 1, 0)
                sliderFill.BackgroundColor3 = COLORS.accent
                sliderFill.BorderSizePixel = 0
                sliderFill.Parent = sliderTrack
                corner(sliderFill, 4)
                sliderKnob = Instance.new("Frame")
                sliderKnob.Size = UDim2.fromOffset(12, 12)
                sliderKnob.AnchorPoint = Vector2.new(0.5, 0.5)
                sliderKnob.Position = UDim2.new(math.clamp((f.Value or 1) / 200, 0, 1), 0, 0.5, 0)
                sliderKnob.BackgroundColor3 = COLORS.text
                sliderKnob.BorderSizePixel = 0
                sliderKnob.Parent = sliderTrack
                corner(sliderKnob, 6)

                local function setControlValue(raw)
                    local n = tonumber(raw)
                    if not n then n = f.Value or 1 end
                    n = math.clamp(math.floor(n + 0.5), 1, 200)
                    f.Value = n
                    valueBox.Text = tostring(n)
                    local alpha = n / 200
                    sliderFill.Size = UDim2.new(alpha, 0, 1, 0)
                    sliderKnob.Position = UDim2.new(alpha, 0, 0.5, 0)
                    if f.Enabled then
                        local _, hum = getCharacterParts()
                        if hum then
                            if f.Id == "walk_speed" then hum.WalkSpeed = n
                            else hum.UseJumpPower = true; hum.JumpPower = n end
                        end
                    end
                end
                track(valueBox.FocusLost:Connect(function()
                    setControlValue(valueBox.Text)
                end))
                local draggingSlider = false
                local function updateFromX(x)
                    local width = math.max(1, sliderTrack.AbsoluteSize.X)
                    local alpha = math.clamp((x - sliderTrack.AbsolutePosition.X) / width, 0, 1)
                    setControlValue(1 + math.floor(alpha * 199 + 0.5))
                end
                track(sliderTrack.InputBegan:Connect(function(input)
                    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                        draggingSlider = true
                        updateFromX(input.Position.X)
                    end
                end))
                track(UserInputService.InputChanged:Connect(function(input)
                    if draggingSlider and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
                        updateFromX(input.Position.X)
                    end
                end))
                track(UserInputService.InputEnded:Connect(function(input)
                    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                        draggingSlider = false
                    end
                end))
            end

            local targetBox
            if f.Id == "teleport_player" then
                targetBox = Instance.new("TextButton")
                targetBox.Size = UDim2.fromOffset(112, 26)
                targetBox.Position = UDim2.new(1, -122, 0.5, -13)
                targetBox.BackgroundColor3 = COLORS.off
                targetBox.BorderSizePixel = 0
                targetBox.Text = "Players  ▸"
                targetBox.TextColor3 = COLORS.text
                targetBox.Font = Enum.Font.GothamBold
                targetBox.TextSize = 10
                targetBox.Parent = row
                corner(targetBox, 6)
            end
            rows[#rows + 1] = { feature = f, status = statusLabel, toggle = toggle, input = targetBox, valueBox = valueBox }
        end

        -- Atalho independente para o painel de localizações salvas.
        if categoryName == "Player" then
            page.Size = UDim2.new(1, 0, 0, pageHeight + 40)
            local locationLauncher = Instance.new("TextButton")
            locationLauncher.Name = "SavedLocationsLauncher"
            locationLauncher.LayoutOrder = nextOrder()
            locationLauncher.Size = UDim2.new(1, 0, 0, 34)
            locationLauncher.BackgroundColor3 = COLORS.off
            locationLauncher.BorderSizePixel = 0
            locationLauncher.Text = "Saved Locations   ▸"
            locationLauncher.TextColor3 = COLORS.text
            locationLauncher.Font = Enum.Font.GothamBold
            locationLauncher.TextSize = 11
            locationLauncher.Parent = page
            corner(locationLauncher, 7)
            savedLocationsLauncher = locationLauncher
        end

        local tab = Instance.new("TextButton")
        tab.LayoutOrder = nextOrder()
        tab.Size = UDim2.new(1 / #categoryOrder, -4, 1, 0)
        tab.BackgroundColor3 = COLORS.off
        tab.BorderSizePixel = 0
        tab.Text = categoryName
        tab.TextColor3 = COLORS.text
        tab.Font = Enum.Font.GothamBold
        tab.TextSize = 9
        tab.TextTruncate = Enum.TextTruncate.AtEnd
        tab.Parent = tabBar
        corner(tab, 7)
        tabButtons[categoryName] = tab
        track(tab.MouseButton1Click:Connect(function()
            selectTab(categoryName)
        end))
    end

    if categoryOrder[1] then
        selectTab(categoryOrder[1])
    end

    -- Painel lateral de seleção de jogadores, anexado visualmente à janela principal.
    local playerPanel = Instance.new("Frame")
    playerPanel.Name = "PlayerPicker"
    playerPanel.Size = UDim2.fromOffset(190, 250)
    playerPanel.BackgroundColor3 = COLORS.window
    playerPanel.BackgroundTransparency = 0.03
    playerPanel.BorderSizePixel = 0
    playerPanel.Visible = false
    playerPanel.ZIndex = 20
    playerPanel.Parent = gui
    corner(playerPanel, 10)
    local panelStroke = Instance.new("UIStroke")
    panelStroke.Color = Color3.fromRGB(60, 66, 86)
    panelStroke.Transparency = 0.25
    panelStroke.Parent = playerPanel

    local panelTitle = Instance.new("TextLabel")
    panelTitle.Size = UDim2.new(1, -42, 0, 30)
    panelTitle.Position = UDim2.fromOffset(10, 2)
    panelTitle.BackgroundTransparency = 1
    panelTitle.Text = "Jogadores na instância"
    panelTitle.TextColor3 = COLORS.text
    panelTitle.Font = Enum.Font.GothamBold
    panelTitle.TextSize = 11
    panelTitle.TextXAlignment = Enum.TextXAlignment.Left
    panelTitle.ZIndex = 21
    panelTitle.Parent = playerPanel

    local panelClose = Instance.new("TextButton")
    panelClose.Size = UDim2.fromOffset(24, 22)
    panelClose.Position = UDim2.new(1, -30, 0, 5)
    panelClose.BackgroundColor3 = COLORS.off
    panelClose.BorderSizePixel = 0
    panelClose.Text = "×"
    panelClose.TextColor3 = COLORS.text
    panelClose.Font = Enum.Font.GothamBold
    panelClose.TextSize = 15
    panelClose.ZIndex = 21
    panelClose.Parent = playerPanel
    corner(panelClose, 5)
    track(panelClose.MouseButton1Click:Connect(function() playerPanel.Visible = false end))

    local playerScroll = Instance.new("ScrollingFrame")
    playerScroll.Position = UDim2.fromOffset(8, 34)
    playerScroll.Size = UDim2.new(1, -16, 1, -42)
    playerScroll.BackgroundTransparency = 1
    playerScroll.BorderSizePixel = 0
    playerScroll.ScrollBarThickness = 4
    playerScroll.ScrollBarImageColor3 = COLORS.accent
    playerScroll.CanvasSize = UDim2.fromOffset(0, 0)
    playerScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    playerScroll.ZIndex = 21
    playerScroll.Parent = playerPanel
    local playerListLayout = Instance.new("UIListLayout")
    playerListLayout.Padding = UDim.new(0, 5)
    playerListLayout.SortOrder = Enum.SortOrder.Name
    playerListLayout.Parent = playerScroll

    local playerListSignature = nil
    local function refreshPlayerList()
        local current = {}
        for _, player in ipairs(Players:GetPlayers()) do
            if player ~= LocalPlayer then current[#current + 1] = tostring(player.UserId) end
        end
        table.sort(current)
        local signature = table.concat(current, ",")
        if signature == playerListSignature then return end
        playerListSignature = signature
        for _, child in ipairs(playerScroll:GetChildren()) do
            if child ~= playerListLayout then child:Destroy() end
        end
        local connected = {}
        for _, player in ipairs(Players:GetPlayers()) do
            if player ~= LocalPlayer then connected[#connected + 1] = player end
        end
        table.sort(connected, function(a, b)
            return (a.DisplayName .. a.Name):lower() < (b.DisplayName .. b.Name):lower()
        end)
        if #connected == 0 then
            local empty = Instance.new("TextLabel")
            empty.Size = UDim2.new(1, -4, 0, 34)
            empty.BackgroundTransparency = 1
            empty.Text = "Nenhum outro jogador conectado"
            empty.TextColor3 = COLORS.sub
            empty.Font = Enum.Font.Gotham
            empty.TextSize = 10
            empty.TextWrapped = true
            empty.ZIndex = 22
            empty.Parent = playerScroll
            return
        end
        for _, player in ipairs(connected) do
            local button = Instance.new("TextButton")
            button.Name = "Player_" .. player.UserId
            button.Size = UDim2.new(1, -4, 0, 32)
            button.BackgroundColor3 = COLORS.row
            button.BorderSizePixel = 0
            button.Text = player.DisplayName .. "  (@" .. player.Name .. ")"
            button.TextColor3 = COLORS.text
            button.Font = Enum.Font.GothamMedium
            button.TextSize = 10
            button.TextTruncate = Enum.TextTruncate.AtEnd
            button.ZIndex = 22
            button.Parent = playerScroll
            corner(button, 6)
            track(button.MouseButton1Click:Connect(function()
                if not player.Parent then
                    TeleportPlayer:SetStatus("Jogador não está mais na instância", "warn")
                else
                    TeleportPlayer.PendingTarget = player
                    setEnabled(TeleportPlayer, true)
                    playerPanel.Visible = false
                end
            end))
        end
    end

    for _, rowInfo in ipairs(rows) do
        if rowInfo.feature.Id == "teleport_player" and rowInfo.input then
            track(rowInfo.input.MouseButton1Click:Connect(function()
                refreshPlayerList()
                playerPanel.Visible = not playerPanel.Visible
                if playerPanel.Visible then
                    local pos = main.AbsolutePosition
                    playerPanel.Position = UDim2.fromOffset(pos.X + main.AbsoluteSize.X + 8, pos.Y + 36)
                end
            end))
            break
        end
    end

    -- Mantém o painel ao lado da janela mesmo quando a janela principal é arrastada.
    task.spawn(function()
        while alive and gui and gui.Parent do
            if playerPanel.Visible then
                local pos = main.AbsolutePosition
                playerPanel.Position = UDim2.fromOffset(pos.X + main.AbsoluteSize.X + 8, pos.Y + 36)
                refreshPlayerList()
            end
            task.wait(1)
        end
    end)

    -----------------------------------------------------------------
    -- Painel independente: localizações salvas pelo jogador
    -----------------------------------------------------------------
    local locationsPanel = Instance.new("Frame")
    locationsPanel.Name = "SavedLocationsPanel"
    locationsPanel.Size = UDim2.fromOffset(310, 310)
    locationsPanel.Position = UDim2.fromOffset(380, 100)
    locationsPanel.BackgroundColor3 = COLORS.window
    locationsPanel.BackgroundTransparency = 0.03
    locationsPanel.BorderSizePixel = 0
    locationsPanel.Visible = false
    locationsPanel.ZIndex = 40
    locationsPanel.Parent = gui
    corner(locationsPanel, 10)
    local locationsStroke = Instance.new("UIStroke")
    locationsStroke.Color = Color3.fromRGB(60, 66, 86)
    locationsStroke.Transparency = 0.25
    locationsStroke.Parent = locationsPanel

    local locationsHeader = Instance.new("Frame")
    locationsHeader.Size = UDim2.new(1, 0, 0, 34)
    locationsHeader.BackgroundColor3 = COLORS.header
    locationsHeader.BorderSizePixel = 0
    locationsHeader.ZIndex = 41
    locationsHeader.Parent = locationsPanel
    corner(locationsHeader, 10)
    local locationsTitle = Instance.new("TextLabel")
    locationsTitle.Size = UDim2.new(1, -100, 1, 0)
    locationsTitle.Position = UDim2.fromOffset(10, 0)
    locationsTitle.BackgroundTransparency = 1
    locationsTitle.Text = "Localizações salvas"
    locationsTitle.TextColor3 = COLORS.text
    locationsTitle.Font = Enum.Font.GothamBold
    locationsTitle.TextSize = 12
    locationsTitle.TextXAlignment = Enum.TextXAlignment.Left
    locationsTitle.ZIndex = 42
    locationsTitle.Parent = locationsHeader

    local function makeHeaderButton(parent, text, x, callback)
        local b = Instance.new("TextButton")
        b.Size = UDim2.fromOffset(24, 22)
        b.Position = UDim2.new(1, x, 0, 6)
        b.BackgroundColor3 = COLORS.off
        b.BorderSizePixel = 0
        b.Text = text
        b.TextColor3 = COLORS.text
        b.Font = Enum.Font.GothamBold
        b.TextSize = 13
        b.ZIndex = 43
        b.Parent = parent
        corner(b, 5)
        track(b.MouseButton1Click:Connect(callback))
        return b
    end

    local locationsBody = Instance.new("Frame")
    locationsBody.Position = UDim2.fromOffset(0, 34)
    locationsBody.Size = UDim2.new(1, 0, 1, -34)
    locationsBody.BackgroundTransparency = 1
    locationsBody.ZIndex = 41
    locationsBody.Parent = locationsPanel
    local locationsMinimized = false
    makeHeaderButton(locationsHeader, "–", -60, function()
        locationsMinimized = not locationsMinimized
        locationsBody.Visible = not locationsMinimized
        locationsPanel.Size = locationsMinimized and UDim2.fromOffset(310, 34) or UDim2.fromOffset(310, 310)
    end)
    makeHeaderButton(locationsHeader, "×", -30, function()
        locationsPanel.Visible = false
    end)

    local locationsScroll = Instance.new("ScrollingFrame")
    locationsScroll.Position = UDim2.fromOffset(8, 7)
    locationsScroll.Size = UDim2.new(1, -16, 1, -54)
    locationsScroll.BackgroundTransparency = 1
    locationsScroll.BorderSizePixel = 0
    locationsScroll.ScrollBarThickness = 4
    locationsScroll.ScrollBarImageColor3 = COLORS.accent
    locationsScroll.CanvasSize = UDim2.fromOffset(0, 0)
    locationsScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    locationsScroll.ScrollingDirection = Enum.ScrollingDirection.Y
    locationsScroll.ZIndex = 42
    locationsScroll.Parent = locationsBody
    local locationsLayout = Instance.new("UIListLayout")
    locationsLayout.Padding = UDim.new(0, 7)
    locationsLayout.SortOrder = Enum.SortOrder.LayoutOrder
    locationsLayout.Parent = locationsScroll

    local addLocation = Instance.new("TextButton")
    addLocation.Size = UDim2.new(1, -16, 0, 34)
    addLocation.Position = UDim2.new(0, 8, 1, -41)
    addLocation.BackgroundColor3 = COLORS.accent
    addLocation.BorderSizePixel = 0
    addLocation.Text = "+  Adicionar localização"
    addLocation.TextColor3 = COLORS.text
    addLocation.Font = Enum.Font.GothamBold
    addLocation.TextSize = 11
    addLocation.ZIndex = 43
    addLocation.Parent = locationsBody
    corner(addLocation, 7)

    local savedLocations = {}
    local nextLocationId = 0
    local function refreshLocationCanvas()
        task.defer(function()
            if locationsScroll.Parent then
                locationsScroll.CanvasSize = UDim2.fromOffset(0, locationsLayout.AbsoluteContentSize.Y + 8)
            end
        end)
    end
    local function createLocationEntry()
        nextLocationId += 1
        local id = nextLocationId
        local record = { id = id, name = "", cframe = nil, saveConfirmUntil = 0, deleteConfirmUntil = 0 }
        savedLocations[id] = record

        local card = Instance.new("Frame")
        card.Name = "Location_" .. id
        card.Size = UDim2.new(1, -6, 0, 104)
        card.BackgroundColor3 = COLORS.row
        card.BorderSizePixel = 0
        card.ZIndex = 43
        card.Parent = locationsScroll
        corner(card, 7)

        local nameBox = Instance.new("TextBox")
        nameBox.Position = UDim2.fromOffset(7, 7)
        nameBox.Size = UDim2.new(1, -44, 0, 25)
        nameBox.BackgroundColor3 = COLORS.off
        nameBox.BorderSizePixel = 0
        nameBox.PlaceholderText = "Nome da localização"
        nameBox.Text = ""
        nameBox.TextColor3 = COLORS.text
        nameBox.PlaceholderColor3 = COLORS.sub
        nameBox.Font = Enum.Font.Gotham
        nameBox.TextSize = 10
        nameBox.ClearTextOnFocus = false
        nameBox.ZIndex = 44
        nameBox.Parent = card
        corner(nameBox, 5)
        local deleteButton = Instance.new("TextButton")
        deleteButton.Position = UDim2.new(1, -31, 0, 7)
        deleteButton.Size = UDim2.fromOffset(24, 25)
        deleteButton.BackgroundColor3 = Color3.fromRGB(145, 55, 60)
        deleteButton.BorderSizePixel = 0
        deleteButton.Text = "×"
        deleteButton.TextColor3 = COLORS.text
        deleteButton.Font = Enum.Font.GothamBold
        deleteButton.TextSize = 14
        deleteButton.ZIndex = 44
        deleteButton.Parent = card
        corner(deleteButton, 5)

        local saveButton = Instance.new("TextButton")
        saveButton.Position = UDim2.fromOffset(7, 40)
        saveButton.Size = UDim2.new(0.5, -10, 0, 27)
        saveButton.BackgroundColor3 = COLORS.off
        saveButton.BorderSizePixel = 0
        saveButton.Text = "Salvar posição"
        saveButton.TextColor3 = COLORS.text
        saveButton.Font = Enum.Font.GothamBold
        saveButton.TextSize = 9
        saveButton.ZIndex = 44
        saveButton.Parent = card
        corner(saveButton, 5)
        local teleportButton = Instance.new("TextButton")
        teleportButton.Position = UDim2.new(0.5, 3, 0, 40)
        teleportButton.Size = UDim2.new(0.5, -10, 0, 27)
        teleportButton.BackgroundColor3 = COLORS.accent
        teleportButton.BorderSizePixel = 0
        teleportButton.Text = "Teleportar"
        teleportButton.TextColor3 = COLORS.text
        teleportButton.Font = Enum.Font.GothamBold
        teleportButton.TextSize = 9
        teleportButton.ZIndex = 44
        teleportButton.Parent = card
        corner(teleportButton, 5)
        local status = Instance.new("TextLabel")
        status.Position = UDim2.fromOffset(8, 72)
        status.Size = UDim2.new(1, -16, 0, 23)
        status.BackgroundTransparency = 1
        status.Text = "Ainda não salva"
        status.TextColor3 = COLORS.sub
        status.Font = Enum.Font.Gotham
        status.TextSize = 9
        status.TextXAlignment = Enum.TextXAlignment.Left
        status.ZIndex = 44
        status.Parent = card

        track(nameBox.FocusLost:Connect(function() record.name = nameBox.Text end))
        track(saveButton.MouseButton1Click:Connect(function()
            record.name = nameBox.Text
            if record.name:gsub("%s", "") == "" then
                status.Text = "Digite um nome primeiro"
                status.TextColor3 = COLORS.kinds.err or Color3.fromRGB(255, 100, 100)
                return
            end
            if os.clock() > record.saveConfirmUntil then
                record.saveConfirmUntil = os.clock() + 1.5
                saveButton.Text = record.cframe and "Clique novamente p/ substituir" or "Clique novamente p/ salvar"
                status.Text = "Confirme em até 1,5 segundo"
                return
            end
            local root = getCharacterParts()
            if not root then status.Text = "Personagem indisponível"; return end
            record.cframe = root.CFrame
            record.saveConfirmUntil = 0
            saveButton.Text = "Salvar posição"
            status.Text = "Posição salva: " .. record.name
            status.TextColor3 = COLORS.kinds.ok or COLORS.text
        end))
        track(teleportButton.MouseButton1Click:Connect(function()
            if not record.cframe then status.Text = "Salve uma posição primeiro"; return end
            local root = getCharacterParts()
            if not root then status.Text = "Personagem indisponível"; return end
            root.CFrame = record.cframe
            status.Text = "Teleportado para " .. (record.name ~= "" and record.name or "localização")
            status.TextColor3 = COLORS.kinds.ok or COLORS.text
        end))
        track(deleteButton.MouseButton1Click:Connect(function()
            if os.clock() > record.deleteConfirmUntil then
                record.deleteConfirmUntil = os.clock() + 1.5
                deleteButton.Text = "?"
                status.Text = "Clique novamente para apagar"
                return
            end
            savedLocations[id] = nil
            card:Destroy()
            refreshLocationCanvas()
        end))
        refreshLocationCanvas()
    end
    track(addLocation.MouseButton1Click:Connect(createLocationEntry))

    -- Arraste exclusivo: não reutiliza o estado de arraste da janela principal.
    local locationsDragging, locationsDragStart, locationsStartPos = false, nil, nil
    track(locationsHeader.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            locationsDragging, locationsDragStart, locationsStartPos = true, input.Position, locationsPanel.Position
        end
    end))
    track(UserInputService.InputChanged:Connect(function(input)
        if locationsDragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - locationsDragStart
            locationsPanel.Position = UDim2.new(locationsStartPos.X.Scale, locationsStartPos.X.Offset + delta.X,
                locationsStartPos.Y.Scale, locationsStartPos.Y.Offset + delta.Y)
        end
    end))
    track(UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            locationsDragging = false
        end
    end))
    if savedLocationsLauncher then
        track(savedLocationsLauncher.MouseButton1Click:Connect(function()
            locationsPanel.Visible = not locationsPanel.Visible
            if locationsPanel.Visible then
                local pos = main.AbsolutePosition
                locationsPanel.Position = UDim2.fromOffset(pos.X + main.AbsoluteSize.X + 8, pos.Y + 300)
            end
        end))
    end

    local note = Instance.new("TextLabel")
    note.LayoutOrder = nextOrder()
    note.Size = UDim2.new(1, 0, 0, 40)
    note.BackgroundTransparency = 1
    note.Text = "Fly: WASD + Espaço/Ctrl. Noclip atravessa colisões. Abra Players para selecionar alguém e teleportar. Rejoin e Server Hop são ações pontuais."
    note.TextColor3 = COLORS.sub
    note.Font = Enum.Font.Gotham
    note.TextSize = 10
    note.TextWrapped = true
    note.TextXAlignment = Enum.TextXAlignment.Left
    note.TextYAlignment = Enum.TextYAlignment.Top
    note.Parent = body

    -- Atualização da tela (leve: só mexe no que mudou)
    task.spawn(function()
        while alive do
            for _, r in ipairs(rows) do
                local f = r.feature
                if r.status.Text ~= f.Status then r.status.Text = f.Status end
                r.status.TextColor3 = COLORS.kinds[f.Kind] or COLORS.kinds.idle
                local wantText = f.Enabled and "ON" or "OFF"
                if r.toggle then
                    if r.toggle.Text ~= wantText then
                        r.toggle.Text = wantText
                        r.toggle.BackgroundColor3 = f.Enabled and COLORS.on or COLORS.off
                    end
                end
                if r.valueBox and not r.valueBox:IsFocused() and r.valueBox.Text ~= tostring(f.Value) then
                    r.valueBox.Text = tostring(f.Value)
                end
            end
            task.wait(0.4)
        end
    end)
end

---------------------------------------------------------------------
-- Encerramento limpo
---------------------------------------------------------------------
local api = {}
function api.Destroy()
    alive = false -- todos os loops e esperas terminam; teleportes em curso voltam ao ponto original
    for _, f in ipairs(Features) do
        if f.Enabled then
            f.Enabled = false
            if f.OnDisable then pcall(f.OnDisable, f) end
        end
        if f.CleanResources then f:CleanResources() end
    end
    for _, c in ipairs(connections) do pcall(function() c:Disconnect() end) end
    connections = {}
    if gui then pcall(function() gui:Destroy() end) end
    env.__TBOD_AUTO = nil
end
env.__TBOD_AUTO = api
function api.SetEnabled(id, on)
    for _, f in ipairs(Features) do
        if f.Id == id then setEnabled(f, on) end
    end
end
function api.SetTeleportTarget(name)
    TeleportPlayer.PendingTarget=tostring(name or "")
    setEnabled(TeleportPlayer,true)
end
function api.GetCapabilities() return Compat.Capabilities end
function api.StopFeature(id) api.SetEnabled(id,false) end

---------------------------------------------------------------------
-- Início
---------------------------------------------------------------------
local okStart, errStart = pcall(function()
    -- detecta caixas que apareçam depois (nome/classe vistos no log: Model "MysteryCrate")
    track(Workspace.DescendantAdded:Connect(function(inst)
        if Crate.Enabled and inst.Name == GAME.CrateModelName then
            pcall(registerCrate, inst)
        end
        if SurgeCell.Enabled and inst.Name == GAME.SurgeCellModelName and inst:IsA("Model") then
            pcall(registerSurgeCell, inst)
        end
    end))
    startNetListener()
    buildGui()
    for _, f in ipairs(Features) do startFeatureLoop(f) end
    log("iniciado. Métodos de clique disponíveis: "
        .. (#CLICK_METHODS > 0 and table.concat(CLICK_METHODS, ", ") or "NENHUM"))
end)
if not okStart then
    log("falha ao iniciar: " .. tostring(errStart))
    pcall(api.Destroy)
end
