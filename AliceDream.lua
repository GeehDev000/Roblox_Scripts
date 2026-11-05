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
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer = Players.LocalPlayer

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

local function getCharacterParts()
    local char = LocalPlayer.Character
    if not char then return nil end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    local hum = char:FindFirstChildOfClass("Humanoid")
    if hrp and hum and hum.Health > 0 then return hrp, hum end
    return nil
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
-- Interface gráfica
---------------------------------------------------------------------
local gui

local COLORS = {
    -- Tema ametista: fundos ameixa profundos, violeta e rosa orchid.
    window = Color3.fromRGB(25, 15, 35),
    header = Color3.fromRGB(57, 29, 72),
    row = Color3.fromRGB(43, 27, 56),
    accent = Color3.fromRGB(190, 112, 255),
    accentPink = Color3.fromRGB(255, 112, 190),
    text = Color3.fromRGB(250, 242, 255),
    sub = Color3.fromRGB(190, 171, 207),
    on = Color3.fromRGB(226, 91, 174),
    off = Color3.fromRGB(78, 51, 94),
    border = Color3.fromRGB(119, 76, 145),
    kinds = {
        idle = Color3.fromRGB(190, 171, 207),
        ok = Color3.fromRGB(137, 224, 190),
        warn = Color3.fromRGB(255, 202, 133),
        err = Color3.fromRGB(255, 125, 164),
        work = Color3.fromRGB(203, 155, 255),
    },
}

local function corner(parent, radius)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, radius)
    c.Parent = parent
    return c
end

local function addGradient(parent, colorA, colorB, rotation)
    local gradient = Instance.new("UIGradient")
    gradient.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, colorA),
        ColorSequenceKeypoint.new(1, colorB),
    })
    gradient.Rotation = rotation or 0
    gradient.Parent = parent
    return gradient
end

local savedLocationsLauncher

local function buildGui()
    gui = Instance.new("ScreenGui")
    gui.Name = "TycoonHelper"
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 999
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Global
    local ok = pcall(function() gui.Parent = (Compat.GetHui and Compat.GetHui()) or game:GetService("CoreGui") end)
    if not ok or not gui.Parent then gui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

    local main = Instance.new("Frame")
    main.Size = UDim2.fromOffset(340, 0)
    main.AutomaticSize = Enum.AutomaticSize.Y
    main.Position = UDim2.new(0, 24, 0, 80)
    main.BackgroundColor3 = COLORS.window
    main.BackgroundTransparency = 0.025
    main.BorderSizePixel = 0
    main.Parent = gui
    corner(main, 14)
    addGradient(main, Color3.fromRGB(31, 17, 45), Color3.fromRGB(20, 13, 31), 35)
    local stroke = Instance.new("UIStroke")
    stroke.Color = COLORS.border
    stroke.Transparency = 0.22
    stroke.Thickness = 1.2
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
    corner(header, 14)
    addGradient(header, Color3.fromRGB(130, 63, 164), Color3.fromRGB(207, 83, 158), 0)

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -80, 1, 0)
    title.Position = UDim2.fromOffset(12, 0)
    title.BackgroundTransparency = 1
    title.Text = "Geeh_000"
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
    headerButton("X", -32, Color3.fromRGB(204, 75, 133), function()
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
            -- Não aplicar UIGradient diretamente no TextButton: no Roblox ele
            -- também colore o texto, reduzindo muito o contraste dos rótulos.
            button.BackgroundColor3 = active
                and Color3.fromRGB(139, 58, 135)
                or Color3.fromRGB(76, 49, 91)
            button.BackgroundTransparency = 0
            button.TextColor3 = Color3.fromRGB(255, 248, 255)
            button.TextTransparency = 0
            button.TextStrokeColor3 = Color3.fromRGB(35, 18, 44)
            button.TextStrokeTransparency = 0.82

            local oldGradient = button:FindFirstChildOfClass("UIGradient")
            if oldGradient then oldGradient:Destroy() end
            local outline = button:FindFirstChild("TabStroke")
            if outline then
                outline.Color = active and COLORS.accentPink or COLORS.border
                outline.Transparency = active and 0.08 or 0.48
                outline.Thickness = active and 1.4 or 1
            end
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
        tab.BackgroundColor3 = Color3.fromRGB(76, 49, 91)
        tab.BorderSizePixel = 0
        tab.AutoButtonColor = false
        tab.Text = categoryName
        tab.TextColor3 = Color3.fromRGB(255, 248, 255)
        tab.TextTransparency = 0
        tab.TextStrokeColor3 = Color3.fromRGB(35, 18, 44)
        tab.TextStrokeTransparency = 0.82
        tab.Font = Enum.Font.GothamBold
        tab.TextSize = 12
        tab.TextTruncate = Enum.TextTruncate.AtEnd
        tab.Parent = tabBar
        corner(tab, 7)
        local tabStroke = Instance.new("UIStroke")
        tabStroke.Name = "TabStroke"
        tabStroke.Color = COLORS.border
        tabStroke.Transparency = 0.48
        tabStroke.Thickness = 1
        tabStroke.Parent = tab
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
    playerPanel.BackgroundTransparency = 0.015
    playerPanel.BorderSizePixel = 0
    playerPanel.Visible = false
    playerPanel.ZIndex = 20
    playerPanel.Parent = gui
    corner(playerPanel, 10)
    local panelStroke = Instance.new("UIStroke")
    panelStroke.Color = COLORS.border
    panelStroke.Transparency = 0.2
    panelStroke.Thickness = 1.1
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
    locationsPanel.BackgroundTransparency = 0.015
    locationsPanel.BorderSizePixel = 0
    locationsPanel.Visible = false
    locationsPanel.ZIndex = 40
    locationsPanel.Parent = gui
    corner(locationsPanel, 10)
    local locationsStroke = Instance.new("UIStroke")
    locationsStroke.Color = COLORS.border
    locationsStroke.Transparency = 0.2
    locationsStroke.Thickness = 1.1
    locationsStroke.Parent = locationsPanel

    local locationsHeader = Instance.new("Frame")
    locationsHeader.Size = UDim2.new(1, 0, 0, 34)
    locationsHeader.BackgroundColor3 = COLORS.header
    locationsHeader.BorderSizePixel = 0
    locationsHeader.ZIndex = 41
    locationsHeader.Parent = locationsPanel
    corner(locationsHeader, 10)
    addGradient(locationsHeader, Color3.fromRGB(130, 63, 164), Color3.fromRGB(207, 83, 158), 0)
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
    addGradient(addLocation, Color3.fromRGB(151, 83, 222), Color3.fromRGB(229, 91, 174), 0)

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
        deleteButton.BackgroundColor3 = Color3.fromRGB(174, 61, 111)
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
        addGradient(teleportButton, Color3.fromRGB(139, 82, 211), Color3.fromRGB(205, 91, 183), 0)
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
    note.Text = "Para você, meu amor, Alice_Dream, um sonho que me faz duvidar se realmente quero acordar para a realidade."
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
    buildGui()
    for _, f in ipairs(Features) do startFeatureLoop(f) end
    log("iniciado. Abas: Player e Servidor.")
end)
if not okStart then
    log("falha ao iniciar: " .. tostring(errStart))
    pcall(api.Destroy)
end
