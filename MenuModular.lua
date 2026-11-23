--[[
    ============================================================
    Hp Team Pro V1 - Debug Tool
    LocalScript → StarterPlayer > StarterPlayerScripts
    Chỉ dùng trong game của chính bạn
    ============================================================
--]]

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService     = game:GetService("TweenService")
local Lighting         = game:GetService("Lighting")
local CollectionService= game:GetService("CollectionService")

local lp     = Players.LocalPlayer
local camera = workspace.CurrentCamera

local function getChar()  return lp.Character or lp.CharacterAdded:Wait() end
local function getRoot()  local c=getChar() return c and c:FindFirstChild("HumanoidRootPart") end
local function getHum()   local c=getChar() return c and c:FindFirstChildOfClass("Humanoid") end

--------------------------------------------------------------------------------
-- MODULE: StateManager
--------------------------------------------------------------------------------
local SM = {}
SM.States    = {}
SM.Params    = {
    ScanRange    = 150,
    FlySpeed     = 50,
    WalkSpeed    = 16,
    DroneHeight  = 10,
    HitboxSize   = 10,
    BuryDepth    = -5,
    FlyAirSpeed  = 50,
    HeadDownDepth= 3,
}
SM.Snapshots = {}

function SM:Set(k,v)   self.States[k]=v end
function SM:Get(k)     return self.States[k]==true end
function SM:Toggle(k)  self.States[k]=not self.States[k]; return self.States[k] end
function SM:Snap(k,v)  self.Snapshots[k]=v end
function SM:Load(k)    return self.Snapshots[k] end

--------------------------------------------------------------------------------
-- MODULE: TargetScanner
--------------------------------------------------------------------------------
local TS = {}
TS._cache        = {}
TS._lastScan     = 0
TS._scanInterval = 0.2

function TS:IsValid(model)
    if not model or not model.Parent then return false end
    for _,p in ipairs(Players:GetPlayers()) do
        if p.Character == model then return false end
    end
    local hum  = model:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then return false end
    local root = model.PrimaryPart or model:FindFirstChild("HumanoidRootPart")
    if not root then return false end
    local myRoot = getRoot()
    if not myRoot then return false end
    return (root.Position - myRoot.Position).Magnitude <= SM.Params.ScanRange
end

function TS:Scan()
    local now = os.clock()
    if now - self._lastScan < self._scanInterval then return self._cache end
    self._lastScan = now
    local myRoot = getRoot()
    if not myRoot then self._cache={} return self._cache end

    local list = {}
    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("Model") and obj ~= getChar() then
            if self:IsValid(obj) then
                local root = obj.PrimaryPart or obj:FindFirstChild("HumanoidRootPart")
                table.insert(list, {
                    model = obj,
                    root  = root,
                    dist  = (root.Position - myRoot.Position).Magnitude
                })
            end
        end
    end
    table.sort(list, function(a,b) return a.dist < b.dist end)
    self._cache = list
    return list
end

function TS:Nearest()
    local list = self:Scan()
    return list[1]
end

--------------------------------------------------------------------------------
-- MODULE: CombatEngine
--------------------------------------------------------------------------------
local CE = {}
CE._lock       = nil   -- mục tiêu đang khóa
CE._connections= {}

-- Hook tấn công: thay nội dung hàm này theo cơ chế vũ khí/skill của game bạn
-- target = Model của mục tiêu, mode = "normal"/"air"/"bury"
function CE.AttackHook(target, mode)
    -- VD: kích hoạt tool trong tay
    local char = getChar()
    local tool = char and char:FindFirstChildOfClass("Tool")
    if tool then
        local fireEvent = tool:FindFirstChild("Fire") or tool:FindFirstChild("Shoot")
        if fireEvent and fireEvent:IsA("RemoteEvent") then
            -- fireEvent:FireServer() -- bỏ comment nếu game dùng RemoteEvent
        end
        -- Mô phỏng click chuột
        local mouse = lp:GetMouse()
        if mouse then
            -- mouse1click() -- nếu dùng executor có hàm này
        end
    end
end

-- Khóa mục tiêu thông minh, tự chuyển khi mục tiêu chết/biến mất
function CE:LockTarget(target)
    self._lock = target
end
function CE:GetLock()
    if not self._lock then return nil end
    if not TS:IsValid(self._lock.model) then
        self._lock = nil
        self._lock = TS:Nearest()
    end
    return self._lock
end

-- Tele Dron: lơ lửng phía trên mục tiêu và tấn công hướng xuống
CE._dronConn = nil
function CE:StartTeleDron()
    if self._dronConn then self._dronConn:Disconnect() end
    self._dronConn = RunService.Heartbeat:Connect(function()
        if not SM:Get("TeleDron") then return end
        local t = TS:Nearest()
        if not t then return end
        local root = getRoot()
        if not root then return end
        local targetPos = t.root.Position + Vector3.new(0, SM.Params.DroneHeight, 0)
        root.CFrame = CFrame.new(targetPos)
        root.AssemblyLinearVelocity  = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
        CE.AttackHook(t.model, "air")
    end)
end
function CE:StopTeleDron()
    if self._dronConn then self._dronConn:Disconnect(); self._dronConn=nil end
end

-- Hitbox All Mod: phóng to HumanoidRootPart của tất cả Mod
CE._hitboxConns = {}
function CE:StartHitbox()
    for _, conn in ipairs(self._hitboxConns) do conn:Disconnect() end
    self._hitboxConns = {}
    local function applyHitbox(model)
        if not TS:IsValid(model) then return end
        local root = model.PrimaryPart or model:FindFirstChild("HumanoidRootPart")
        if root then
            SM:Snap("HitboxSize_"..model.Name, root.Size)
            root.Size = Vector3.new(SM.Params.HitboxSize, SM.Params.HitboxSize, SM.Params.HitboxSize)
        end
    end
    local conn = RunService.Heartbeat:Connect(function()
        if not SM:Get("HitboxAll") then return end
        for _, t in ipairs(TS:Scan()) do applyHitbox(t.model) end
    end)
    table.insert(self._hitboxConns, conn)
end
function CE:StopHitbox()
    for _, conn in ipairs(self._hitboxConns) do conn:Disconnect() end
    self._hitboxConns = {}
    -- Khôi phục kích thước gốc
    for _, t in ipairs(TS:Scan()) do
        local root = t.model.PrimaryPart or t.model:FindFirstChild("HumanoidRootPart")
        if root then
            local orig = SM:Load("HitboxSize_"..t.model.Name)
            if orig then root.Size = orig end
        end
    end
end

-- Tele Kill: dịch chuyển đến mục tiêu gần nhất và tấn công
CE._teleKillConn = nil
function CE:StartTeleKill()
    if self._teleKillConn then self._teleKillConn:Disconnect() end
    self._teleKillConn = RunService.Heartbeat:Connect(function()
        if not SM:Get("TeleKill") then return end
        local t = TS:Nearest()
        if not t then return end
        local root = getRoot()
        if not root then return end
        local offset = Vector3.new(0, 2, -3)
        root.CFrame = CFrame.new(t.root.Position) * CFrame.new(offset)
        root.AssemblyLinearVelocity = Vector3.zero
        CE.AttackHook(t.model, "normal")
    end)
end
function CE:StopTeleKill()
    if self._teleKillConn then self._teleKillConn:Disconnect(); self._teleKillConn=nil end
end

-- Aimbot: hướng camera mượt vào mục tiêu gần nhất
CE._aimbotConn = nil
function CE:StartAimbot()
    if self._aimbotConn then self._aimbotConn:Disconnect() end
    self._aimbotConn = RunService.RenderStepped:Connect(function()
        if not SM:Get("Aimbot") then return end
        local t = TS:Nearest()
        if not t then return end
        local goal = CFrame.new(camera.CFrame.Position, t.root.Position)
        camera.CFrame = camera.CFrame:Lerp(goal, 0.2)
    end)
end
function CE:StopAimbot()
    if self._aimbotConn then self._aimbotConn:Disconnect(); self._aimbotConn=nil end
end

-- Model Độn Thổ: hạ tất cả Mod xuống đất
CE._buryConn = nil
function CE:StartBury()
    if self._buryConn then self._buryConn:Disconnect() end
    self._buryConn = RunService.Heartbeat:Connect(function()
        if not SM:Get("BuryMod") then return end
        for _, t in ipairs(TS:Scan()) do
            local root = t.root
            if root then
                root.CFrame = CFrame.new(root.Position.X, SM.Params.BuryDepth, root.Position.Z)
                root.AssemblyLinearVelocity = Vector3.zero
            end
        end
    end)
end
function CE:StopBury()
    if self._buryConn then self._buryConn:Disconnect(); self._buryConn=nil end
end

-- Model Head Down: thân đứng yên tại chỗ, chỉ đầu bị cắm xuống đất, vô hiệu tấn công
-- FIX: không lật CFrame của root (nguyên nhân gây bay lên trời do vật lý đẩy ngược).
-- Thay vào đó giữ root cố định tuyệt đối và chỉ dịch chuyển riêng Head xuống dưới.
CE._headDownConn = nil
CE._headDownData = {} -- [model] = { walkSpeed, jumpPower } để khôi phục đúng khi tắt

function CE:StartHeadDown()
    if self._headDownConn then
        self._headDownConn:Disconnect()
        self._headDownConn = nil
    end
    self._headDownData = {}

    self._headDownConn = RunService.Heartbeat:Connect(function()
        if not SM:Get("HeadDown") then return end

        for _, t in ipairs(TS:Scan()) do
            local model = t.model
            local root  = t.root
            local hum   = model:FindFirstChildOfClass("Humanoid")
            local head  = model:FindFirstChild("Head")

            if not root or not hum or not head then continue end

            -- Lưu snapshot lần đầu gặp mod này (chỉ lưu 1 lần, tránh ghi đè giá trị đã bị khoá)
            if not self._headDownData[model] then
                self._headDownData[model] = {
                    walkSpeed = hum.WalkSpeed,
                    jumpPower = hum.JumpPower,
                }
            end

            -- Vô hiệu khả năng tấn công / di chuyển
            hum.WalkSpeed = 0
            hum.JumpPower  = 0

            -- Giữ thân đứng yên tuyệt đối, không đụng CFrame của root
            root.AssemblyLinearVelocity  = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero

            -- Tính mốc mặt đất từ chân nhân vật rồi cắm đầu xuống theo độ sâu cấu hình
            local groundY  = root.Position.Y - (root.Size.Y / 2)
            local newHeadY = groundY - SM.Params.HeadDownDepth

            head.CFrame = CFrame.new(root.Position.X, newHeadY, root.Position.Z)
            head.AssemblyLinearVelocity  = Vector3.zero
            head.AssemblyAngularVelocity = Vector3.zero
        end
    end)
end

function CE:StopHeadDown()
    if self._headDownConn then
        self._headDownConn:Disconnect()
        self._headDownConn = nil
    end

    -- Khôi phục từng mod đã bị ảnh hưởng, kể cả khi đã rời phạm vi quét
    for model, data in pairs(self._headDownData) do
        if model and model.Parent then
            local hum  = model:FindFirstChildOfClass("Humanoid")
            local head = model:FindFirstChild("Head")
            local root = model.PrimaryPart or model:FindFirstChild("HumanoidRootPart")

            if hum then
                hum.WalkSpeed = data.walkSpeed or 16
                hum.JumpPower  = data.jumpPower or 50
            end

            -- Trả đầu về đúng vị trí trên cổ dựa theo kích thước thực tế
            if head and root then
                local neckOffset = root.Size.Y / 2 + head.Size.Y / 2 + 0.5
                head.CFrame = CFrame.new(root.Position.X, root.Position.Y + neckOffset, root.Position.Z)
            end
        end
    end

    self._headDownData = {}
end

--------------------------------------------------------------------------------
-- MODULE: EspEngine
--------------------------------------------------------------------------------
local EE = {}
EE._drawings = {}  -- [model] = {line, box, nameLabel, distLabel, highlight}
EE._conn     = nil

local function w2s(pos)
    -- Chuyển tọa độ 3D sang 2D màn hình
    local vp = camera.ViewportSize
    local _, onScreen = camera:WorldToViewportPoint(pos)
    if not onScreen then return nil end
    local screenPos = camera:WorldToScreenPoint(pos)
    return Vector2.new(screenPos.X, screenPos.Y), onScreen
end

local function newLine(color)
    local d = Drawing.new("Line")
    d.Visible   = false
    d.Color     = color or Color3.fromRGB(0,255,0)
    d.Thickness = 1
    return d
end
local function newLabel(color)
    local d = Drawing.new("Text")
    d.Visible  = false
    d.Color    = color or Color3.fromRGB(255,255,255)
    d.Size     = 14
    d.Outline  = true
    d.Font     = Drawing.Fonts.UI
    return d
end
local function newBox(color)
    local d = Drawing.new("Square")
    d.Visible   = false
    d.Color     = color or Color3.fromRGB(0,255,0)
    d.Thickness = 1
    d.Filled    = false
    return d
end

function EE:GetOrCreate(model)
    if not self._drawings[model] then
        self._drawings[model] = {
            line      = newLine(Color3.fromRGB(0,255,0)),
            box       = newBox(Color3.fromRGB(0,255,0)),
            nameLabel = newLabel(Color3.fromRGB(255,255,0)),
            distLabel = newLabel(Color3.fromRGB(255,255,255)),
            highlight = nil,
        }
    end
    return self._drawings[model]
end

function EE:CleanModel(model)
    local d = self._drawings[model]
    if not d then return end
    if d.line      then d.line.Visible=false;      d.line:Remove() end
    if d.box       then d.box.Visible=false;       d.box:Remove() end
    if d.nameLabel then d.nameLabel.Visible=false; d.nameLabel:Remove() end
    if d.distLabel then d.distLabel.Visible=false; d.distLabel:Remove() end
    if d.highlight then d.highlight:Destroy() end
    self._drawings[model] = nil
end

function EE:CleanAll()
    for model, _ in pairs(self._drawings) do
        self:CleanModel(model)
    end
end

function EE:Start()
    if self._conn then self._conn:Disconnect() end
    self._conn = RunService.RenderStepped:Connect(function()
        -- Danh sách model hợp lệ hiện tại
        local validSet = {}
        for _, t in ipairs(TS:Scan()) do
            validSet[t.model] = t
        end

        -- Dọn model không còn hợp lệ
        for model, _ in pairs(self._drawings) do
            if not validSet[model] then
                self:CleanModel(model)
            end
        end

        local vp = camera.ViewportSize
        local center = Vector2.new(vp.X/2, 0) -- đỉnh màn hình giữa

        for model, t in pairs(validSet) do
            local d    = self:GetOrCreate(model)
            local root = t.root
            if not root then continue end

            local screenPos, onScreen = w2s(root.Position + Vector3.new(0,2,0))

            -- ESP Line
            if SM:Get("EspLine") and onScreen and screenPos then
                d.line.From    = center
                d.line.To      = screenPos
                d.line.Visible = true
            else
                d.line.Visible = false
            end

            -- ESP Box (đơn giản 2D dùng bounding box)
            if SM:Get("EspBox") and onScreen and screenPos then
                local topPos, _    = w2s(root.Position + Vector3.new(0,3,0))
                local bottomPos, _ = w2s(root.Position + Vector3.new(0,-3,0))
                if topPos and bottomPos then
                    local h = math.abs(topPos.Y - bottomPos.Y)
                    local w = h * 0.5
                    d.box.Position = Vector2.new(screenPos.X - w/2, topPos.Y)
                    d.box.Size     = Vector2.new(w, h)
                    d.box.Visible  = true
                end
            else
                d.box.Visible = false
            end

            -- ESP Name
            if SM:Get("EspName") and onScreen and screenPos then
                d.nameLabel.Position = Vector2.new(screenPos.X, screenPos.Y - 30)
                d.nameLabel.Text     = model.Name
                d.nameLabel.Visible  = true
            else
                d.nameLabel.Visible = false
            end

            -- ESP Distance
            if SM:Get("EspDist") and onScreen and screenPos then
                d.distLabel.Position = Vector2.new(screenPos.X, screenPos.Y - 15)
                d.distLabel.Text     = string.format("%.0f m", t.dist)
                d.distLabel.Visible  = true
            else
                d.distLabel.Visible = false
            end

            -- ESP Hologram (Highlight xuyên tường)
            if SM:Get("EspHolo") then
                if not d.highlight or not d.highlight.Parent then
                    local hl = Instance.new("SelectionBox")
                    hl.Adornee       = model
                    hl.Color3        = Color3.fromRGB(0,255,0)
                    hl.LineThickness = 0.05
                    hl.SurfaceTransparency = 0.5
                    hl.SurfaceColor3 = Color3.fromRGB(0,255,0)
                    hl.Parent        = workspace
                    d.highlight      = hl
                end
            else
                if d.highlight then d.highlight:Destroy(); d.highlight=nil end
            end
        end
    end)
end

function EE:Stop()
    if self._conn then self._conn:Disconnect(); self._conn=nil end
    self:CleanAll()
end

-- ESP Workspace.Items
EE._itemHighlights = {}
EE._itemConn       = nil

function EE:StartWorkspaceEsp()
    if self._itemConn then self._itemConn:Disconnect() end
    self._itemConn = RunService.Heartbeat:Connect(function()
        if not SM:Get("EspWorkspace") then return end
        local folder = workspace:FindFirstChild("Items")
        if not folder then return end
        local existing = {}
        for _, item in ipairs(folder:GetChildren()) do
            existing[item] = true
            if not self._itemHighlights[item] then
                local hl = Instance.new("SelectionBox")
                hl.Adornee       = item
                hl.Color3        = Color3.fromRGB(255,165,0)
                hl.LineThickness = 0.05
                hl.SurfaceTransparency = 0.4
                hl.SurfaceColor3 = Color3.fromRGB(255,165,0)
                hl.Parent        = workspace
                self._itemHighlights[item] = hl
            end
        end
        -- Dọn vật phẩm đã biến mất
        for item, hl in pairs(self._itemHighlights) do
            if not existing[item] or not item.Parent then
                hl:Destroy()
                self._itemHighlights[item] = nil
            end
        end
    end)
end

function EE:StopWorkspaceEsp()
    if self._itemConn then self._itemConn:Disconnect(); self._itemConn=nil end
    for _, hl in pairs(self._itemHighlights) do hl:Destroy() end
    self._itemHighlights = {}
end

--------------------------------------------------------------------------------
-- MODULE: MovementAndWorld
--------------------------------------------------------------------------------
local MW = {}
MW._connections = {}
MW._flyBody     = nil
MW._noclipConn  = nil
MW._flyAirConn  = nil
MW._jumpConn    = nil
MW._speedConn   = nil
MW._nightSnap   = {}

local function disconnectAll(tbl)
    for i, c in ipairs(tbl) do c:Disconnect(); tbl[i]=nil end
end

-- No Clip
function MW:StartNoClip()
    self._noclipConn = RunService.Stepped:Connect(function()
        if not SM:Get("NoClip") then return end
        local char = getChar()
        if not char then return end
        for _, p in ipairs(char:GetDescendants()) do
            if p:IsA("BasePart") then p.CanCollide=false end
        end
    end)
end
function MW:StopNoClip()
    if self._noclipConn then self._noclipConn:Disconnect(); self._noclipConn=nil end
    local char = getChar()
    if not char then return end
    for _, p in ipairs(char:GetDescendants()) do
        if p:IsA("BasePart") then p.CanCollide=true end
    end
end

-- Fly Air: bay trên không, giữ độ cao khi đứng yên
MW._flyAirHeight = nil
MW._flyAirUp     = false
MW._flyAirDown   = false

function MW:StartFlyAir()
    local root = getRoot()
    if not root then return end
    local hum  = getHum()

    -- Tắt gravity bằng BodyPosition
    if self._flyBody then self._flyBody:Destroy() end
    local bp = Instance.new("BodyPosition")
    bp.MaxForce = Vector3.new(1e5,1e5,1e5)
    bp.P        = 1e4
    bp.D        = 500
    bp.Position = root.Position
    bp.Parent   = root
    self._flyBody       = bp
    self._flyAirHeight  = root.Position.Y

    if hum then
        SM:Snap("HumState", hum.PlatformStand)
        hum.PlatformStand = true
    end

    self._flyAirConn = RunService.Heartbeat:Connect(function()
        if not SM:Get("FlyAir") then return end
        local r = getRoot()
        if not r then return end

        local delta = 0
        if self._flyAirUp   then delta =  SM.Params.FlyAirSpeed * 0.016 end
        if self._flyAirDown then delta = -SM.Params.FlyAirSpeed * 0.016 end
        self._flyAirHeight = self._flyAirHeight + delta

        local curPos = r.Position
        self._flyBody.Position = Vector3.new(curPos.X, self._flyAirHeight, curPos.Z)
    end)
end

function MW:StopFlyAir()
    if self._flyAirConn then self._flyAirConn:Disconnect(); self._flyAirConn=nil end
    if self._flyBody    then self._flyBody:Destroy(); self._flyBody=nil end
    local hum = getHum()
    if hum then hum.PlatformStand = SM:Load("HumState") or false end
end

-- Fly Dron: bay úp mặt xuống, cố định độ cao
MW._dronBody   = nil
MW._dronHeight = 6
MW._dronConn2  = nil

function MW:StartFlyDron()
    local root = getRoot()
    if not root then return end
    self._dronHeight = SM.Params.DroneHeight

    if self._dronBody then self._dronBody:Destroy() end
    local bp = Instance.new("BodyPosition")
    bp.MaxForce = Vector3.new(1e5,1e5,1e5)
    bp.P        = 1e4
    bp.D        = 500
    bp.Position = root.Position + Vector3.new(0, self._dronHeight, 0)
    bp.Parent   = root
    self._dronBody = bp

    self._dronConn2 = RunService.Heartbeat:Connect(function()
        if not SM:Get("FlyDron") then return end
        local r = getRoot()
        if not r then return end
        r.CFrame = CFrame.new(r.Position) * CFrame.Angles(math.pi,0,0)
        self._dronBody.Position = Vector3.new(r.Position.X, self._dronHeight, r.Position.Z)
    end)
end
function MW:StopFlyDron()
    if self._dronConn2 then self._dronConn2:Disconnect(); self._dronConn2=nil end
    if self._dronBody  then self._dronBody:Destroy(); self._dronBody=nil end
    local root = getRoot()
    if root then root.CFrame = CFrame.new(root.Position) end
end

-- Fly Down: nằm ngửa, hạ xuống đất
MW._flyDownConn = nil
function MW:StartFlyDown()
    local root = getRoot()
    if not root then return end
    SM:Snap("FlyDown_Y", root.Position.Y)
    self._flyDownConn = RunService.Heartbeat:Connect(function()
        if not SM:Get("FlyDown") then return end
        local r = getRoot()
        if not r then return end
        r.CFrame = CFrame.new(r.Position) * CFrame.Angles(-math.pi/2,0,0)
        r.AssemblyLinearVelocity = Vector3.zero
    end)
end
function MW:StopFlyDown()
    if self._flyDownConn then self._flyDownConn:Disconnect(); self._flyDownConn=nil end
    local root = getRoot()
    if root then root.CFrame = CFrame.new(root.Position) end
end

-- Speed
function MW:SetSpeed(val)
    local hum = getHum()
    if hum then
        SM:Snap("OrigSpeed", hum.WalkSpeed)
        hum.WalkSpeed = val
    end
end
function MW:ResetSpeed()
    local hum = getHum()
    if hum then hum.WalkSpeed = SM:Load("OrigSpeed") or 16 end
end

-- Jumping Air
function MW:StartJumpAir()
    self._jumpConn = UserInputService.JumpRequest:Connect(function()
        if not SM:Get("JumpAir") then return end
        local hum = getHum()
        if hum then
            hum:ChangeState(Enum.HumanoidStateType.Jumping)
        end
    end)
end
function MW:StopJumpAir()
    if self._jumpConn then self._jumpConn:Disconnect(); self._jumpConn=nil end
end

-- Night Vision
function MW:StartNightVision()
    self._nightSnap = {
        ambient      = Lighting.Ambient,
        brightness   = Lighting.Brightness,
        outdoorAmbient= Lighting.OutdoorAmbient,
        fogEnd       = Lighting.FogEnd,
    }
    Lighting.Ambient       = Color3.fromRGB(255,255,255)
    Lighting.Brightness    = 2
    Lighting.OutdoorAmbient= Color3.fromRGB(255,255,255)
    Lighting.FogEnd        = 10000
end
function MW:StopNightVision()
    if self._nightSnap.ambient then
        Lighting.Ambient        = self._nightSnap.ambient
        Lighting.Brightness     = self._nightSnap.brightness
        Lighting.OutdoorAmbient = self._nightSnap.outdoorAmbient
        Lighting.FogEnd         = self._nightSnap.fogEnd
    end
end

-- Fix Lag: tắt particle, shadow, hiệu ứng nặng
function MW:StartFixLag()
    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("ParticleEmitter") or obj:IsA("Trail")
            or obj:IsA("Smoke") or obj:IsA("Sparkles") or obj:IsA("Fire") then
            SM:Snap("FixLag_"..obj:GetFullName().."_enabled", obj.Enabled)
            obj.Enabled = false
        end
    end
    Lighting.GlobalShadows = false
end
function MW:StopFixLag()
    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("ParticleEmitter") or obj:IsA("Trail")
            or obj:IsA("Smoke") or obj:IsA("Sparkles") or obj:IsA("Fire") then
            local orig = SM:Load("FixLag_"..obj:GetFullName().."_enabled")
            obj.Enabled = (orig == nil) and true or orig
        end
    end
    Lighting.GlobalShadows = true
end

--------------------------------------------------------------------------------
-- MODULE: UIController
--------------------------------------------------------------------------------
local GREEN = Color3.fromRGB(0,255,0)
local BLACK = Color3.fromRGB(0,0,0)
local GRAY  = Color3.fromRGB(40,40,40)

local gui = Instance.new("ScreenGui")
gui.Name           = "HpTeamProV1"
gui.ResetOnSpawn   = false
gui.IgnoreGuiInset = true
gui.Parent         = lp:WaitForChild("PlayerGui")

-- Frame chính
local mainFrame = Instance.new("Frame")
mainFrame.Size            = UDim2.fromOffset(280, 400)
mainFrame.Position        = UDim2.fromScale(0.02, 0.1)
mainFrame.BackgroundColor3= BLACK
mainFrame.BorderSizePixel = 0
mainFrame.ClipsDescendants= true
mainFrame.Parent          = gui

local mainStroke = Instance.new("UIStroke")
mainStroke.Color     = GREEN
mainStroke.Thickness = 2
mainStroke.Parent    = mainFrame

-- Titlebar
local titleBar = Instance.new("Frame")
titleBar.Size            = UDim2.new(1,0,0,30)
titleBar.BackgroundColor3= BLACK
titleBar.BorderSizePixel = 0
titleBar.Parent          = mainFrame

local titleLabel = Instance.new("TextLabel")
titleLabel.Size               = UDim2.new(1,-70,1,0)
titleLabel.Position           = UDim2.fromOffset(8,0)
titleLabel.BackgroundTransparency=1
titleLabel.Text               = "Hằng Chân Ngắn Pro V3"
titleLabel.TextColor3         = GREEN
titleLabel.Font               = Enum.Font.GothamBold
titleLabel.TextSize           = 14
titleLabel.TextXAlignment      = Enum.TextXAlignment.Left
titleLabel.Parent             = titleBar

local function makeTopBtn(txt, xOff)
    local b = Instance.new("TextButton")
    b.Size            = UDim2.fromOffset(28,22)
    b.Position        = UDim2.new(1,xOff,0,4)
    b.BackgroundColor3= BLACK
    b.Text            = txt
    b.TextColor3      = GREEN
    b.Font            = Enum.Font.GothamBold
    b.TextSize        = 14
    b.Parent          = titleBar
    local s=Instance.new("UIStroke"); s.Color=GREEN; s.Parent=b
    return b
end
local minBtn   = makeTopBtn("-",-64)
local closeBtn = makeTopBtn("X",-32)

-- Kéo menu
local dragging,dragStart,startPos
titleBar.InputBegan:Connect(function(inp)
    if inp.UserInputType==Enum.UserInputType.MouseButton1
       or inp.UserInputType==Enum.UserInputType.Touch then
        dragging=true; dragStart=inp.Position; startPos=mainFrame.Position
        inp.Changed:Connect(function()
            if inp.UserInputState==Enum.UserInputState.End then dragging=false end
        end)
    end
end)
UserInputService.InputChanged:Connect(function(inp)
    if dragging and (inp.UserInputType==Enum.UserInputType.MouseMovement
       or inp.UserInputType==Enum.UserInputType.Touch) then
        local d=inp.Position-dragStart
        mainFrame.Position=UDim2.new(
            startPos.X.Scale,startPos.X.Offset+d.X,
            startPos.Y.Scale,startPos.Y.Offset+d.Y)
    end
end)

-- Thu nhỏ / mở rộng
local minimized=false
minBtn.MouseButton1Click:Connect(function()
    minimized=not minimized
    mainFrame.Size=minimized and UDim2.fromOffset(280,30) or UDim2.fromOffset(280,400)
end)
closeBtn.MouseButton1Click:Connect(function() gui:Destroy() end)

-- Tab bar
local tabBar = Instance.new("Frame")
tabBar.Size            = UDim2.new(1,0,0,28)
tabBar.Position        = UDim2.fromOffset(0,30)
tabBar.BackgroundColor3= GRAY
tabBar.BorderSizePixel = 0
tabBar.Parent          = mainFrame

local tabNames = {"Main","Esp","Khác"}
local tabBtns  = {}
local tabPages = {}

local function makeTab(name,idx)
    local btn = Instance.new("TextButton")
    btn.Size            = UDim2.new(1/#tabNames,0,1,0)
    btn.Position        = UDim2.new((idx-1)/#tabNames,0,0,0)
    btn.BackgroundColor3= GRAY
    btn.Text            = name
    btn.TextColor3      = GREEN
    btn.Font            = Enum.Font.GothamBold
    btn.TextSize        = 13
    btn.BorderSizePixel = 0
    btn.Parent          = tabBar
    return btn
end

local scrollContainer = Instance.new("Frame")
scrollContainer.Size            = UDim2.new(1,0,1,-58)
scrollContainer.Position        = UDim2.fromOffset(0,58)
scrollContainer.BackgroundTransparency=1
scrollContainer.ClipsDescendants= true
scrollContainer.Parent          = mainFrame

for i,name in ipairs(tabNames) do
    tabBtns[i] = makeTab(name,i)
    local scroll = Instance.new("ScrollingFrame")
    scroll.Size              = UDim2.new(1,0,1,0)
    scroll.BackgroundColor3  = BLACK
    scroll.BorderSizePixel   = 0
    scroll.ScrollBarThickness= 4
    scroll.ScrollBarImageColor3=GREEN
    scroll.CanvasSize        = UDim2.fromOffset(0,0)
    scroll.AutomaticCanvasSize=Enum.AutomaticSize.Y
    scroll.Visible           = i==1
    scroll.Parent            = scrollContainer
    tabPages[i]              = scroll

    local layout = Instance.new("UIListLayout")
    layout.Padding     = UDim.new(0,4)
    layout.Parent      = scroll
    local pad = Instance.new("UIPadding")
    pad.PaddingTop    = UDim.new(0,6)
    pad.PaddingLeft   = UDim.new(0,6)
    pad.PaddingRight  = UDim.new(0,6)
    pad.Parent        = scroll
end

local activeTab = 1
local function switchTab(idx)
    activeTab = idx
    for i,page in ipairs(tabPages) do
        page.Visible = i==idx
        tabBtns[i].BackgroundColor3 = i==idx and Color3.fromRGB(0,80,0) or GRAY
    end
end
switchTab(1)
for i,btn in ipairs(tabBtns) do
    btn.MouseButton1Click:Connect(function() switchTab(i) end)
end

-- Helper tạo toggle button
local function makeToggle(parent, label, onFn, offFn)
    local row = Instance.new("Frame")
    row.Size            = UDim2.new(1,0,0,32)
    row.BackgroundTransparency=1
    row.Parent          = parent

    local btn = Instance.new("TextButton")
    btn.Size            = UDim2.new(1,0,1,0)
    btn.BackgroundColor3= GRAY
    btn.Text            = "[ OFF ]  "..label
    btn.TextColor3      = Color3.fromRGB(180,180,180)
    btn.Font            = Enum.Font.Gotham
    btn.TextSize        = 13
    btn.TextXAlignment  = Enum.TextXAlignment.Left
    btn.BorderSizePixel = 0
    btn.Parent          = row
    local pad=Instance.new("UIPadding"); pad.PaddingLeft=UDim.new(0,8); pad.Parent=btn

    local state = false
    btn.MouseButton1Click:Connect(function()
        state = not state
        if state then
            btn.Text         = "[ ON ]  "..label
            btn.TextColor3   = GREEN
            if onFn then onFn() end
        else
            btn.Text         = "[ OFF ]  "..label
            btn.TextColor3   = Color3.fromRGB(180,180,180)
            if offFn then offFn() end
        end
    end)
    return btn
end

-- Helper tạo slider số
local function makeSlider(parent, label, default, min, max, onChange)
    local row = Instance.new("Frame")
    row.Size            = UDim2.new(1,0,0,42)
    row.BackgroundTransparency=1
    row.Parent          = parent

    local lbl = Instance.new("TextLabel")
    lbl.Size               = UDim2.new(1,0,0,18)
    lbl.BackgroundTransparency=1
    lbl.Text               = label..": "..default
    lbl.TextColor3         = GREEN
    lbl.Font               = Enum.Font.Gotham
    lbl.TextSize           = 13
    lbl.TextXAlignment     = Enum.TextXAlignment.Left
    lbl.Parent             = row
    local pad=Instance.new("UIPadding"); pad.PaddingLeft=UDim.new(0,8); pad.Parent=lbl

    local track = Instance.new("Frame")
    track.Size            = UDim2.new(1,-16,0,8)
    track.Position        = UDim2.new(0,8,0,22)
    track.BackgroundColor3= GRAY
    track.BorderSizePixel = 0
    track.Parent          = row

    local fill = Instance.new("Frame")
    fill.Size            = UDim2.new((default-min)/(max-min),0,1,0)
    fill.BackgroundColor3= GREEN
    fill.BorderSizePixel = 0
    fill.Parent          = track

    local knob = Instance.new("TextButton")
    knob.Size            = UDim2.fromOffset(12,12)
    knob.AnchorPoint     = Vector2.new(0.5,0.5)
    knob.Position        = UDim2.new((default-min)/(max-min),0,0.5,0)
    knob.BackgroundColor3= Color3.new(1,1,1)
    knob.Text            = ""
    knob.BorderSizePixel = 0
    knob.Parent          = track

    local value  = default
    local sliding= false
    knob.MouseButton1Down:Connect(function() sliding=true end)
    UserInputService.InputEnded:Connect(function(inp)
        if inp.UserInputType==Enum.UserInputType.MouseButton1 then sliding=false end
    end)
    UserInputService.InputChanged:Connect(function(inp)
        if sliding and inp.UserInputType==Enum.UserInputType.MouseMovement then
            local trackPos = track.AbsolutePosition
            local trackW   = track.AbsoluteSize.X
            local rel      = math.clamp((inp.Position.X - trackPos.X)/trackW,0,1)
            value = math.floor(min + rel*(max-min))
            fill.Size         = UDim2.new(rel,0,1,0)
            knob.Position     = UDim2.new(rel,0,0.5,0)
            lbl.Text          = label..": "..value
            if onChange then onChange(value) end
        end
    end)
end

--------------------------------------------------------------------------------
-- TAB MAIN
--------------------------------------------------------------------------------
local p1 = tabPages[1]

-- Tele Dron
makeToggle(p1, "Tele Dron",
    function() SM:Set("TeleDron",true);  CE:StartTeleDron() end,
    function() SM:Set("TeleDron",false); CE:StopTeleDron()  end
)
makeSlider(p1,"Drone Height",10,2,50,function(v) SM.Params.DroneHeight=v end)

-- Hitbox All Mod
makeToggle(p1, "Hitbox All Mod",
    function() SM:Set("HitboxAll",true);  CE:StartHitbox() end,
    function() SM:Set("HitboxAll",false); CE:StopHitbox()  end
)
makeSlider(p1,"Hitbox Size",10,5,50,function(v) SM.Params.HitboxSize=v end)

-- Tele Kill
makeToggle(p1, "Tele Kill",
    function() SM:Set("TeleKill",true);  CE:StartTeleKill() end,
    function() SM:Set("TeleKill",false); CE:StopTeleKill()  end
)

-- Aimbot
makeToggle(p1, "Aimbot",
    function() SM:Set("Aimbot",true);  CE:StartAimbot() end,
    function() SM:Set("Aimbot",false); CE:StopAimbot()  end
)

-- Model Độn Thổ
makeToggle(p1, "Model Độn Thổ",
    function() SM:Set("BuryMod",true);  CE:StartBury() end,
    function() SM:Set("BuryMod",false); CE:StopBury()  end
)
makeSlider(p1,"Độ sâu (studs)",-5,-30,0,function(v) SM.Params.BuryDepth=v end)

-- Model Head Down
makeToggle(p1, "Model Head Down",
    function() SM:Set("HeadDown",true);  CE:StartHeadDown() end,
    function() SM:Set("HeadDown",false); CE:StopHeadDown()  end
)
makeSlider(p1,"Head Depth",3,1,15,function(v) SM.Params.HeadDownDepth=v end)

--------------------------------------------------------------------------------
-- TAB ESP
--------------------------------------------------------------------------------
local p2 = tabPages[2]

makeToggle(p2,"Esp Line",
    function() SM:Set("EspLine",true) end,
    function() SM:Set("EspLine",false) end)

makeToggle(p2,"Esp Box",
    function() SM:Set("EspBox",true) end,
    function() SM:Set("EspBox",false) end)

makeToggle(p2,"Esp Name",
    function() SM:Set("EspName",true) end,
    function() SM:Set("EspName",false) end)

makeToggle(p2,"Esp Distance",
    function() SM:Set("EspDist",true) end,
    function() SM:Set("EspDist",false) end)

makeToggle(p2,"Esp Hologram",
    function() SM:Set("EspHolo",true) end,
    function() SM:Set("EspHolo",false) end)

makeToggle(p2,"Esp Workspace.Items",
    function() SM:Set("EspWorkspace",true);  EE:StartWorkspaceEsp() end,
    function() SM:Set("EspWorkspace",false); EE:StopWorkspaceEsp()  end)

-- Khởi động EspEngine ngay
EE:Start()

--------------------------------------------------------------------------------
-- TAB KHÁC
--------------------------------------------------------------------------------
local p3 = tabPages[3]

makeToggle(p3,"Fly Down",
    function() SM:Set("FlyDown",true);  MW:StartFlyDown() end,
    function() SM:Set("FlyDown",false); MW:StopFlyDown()  end)

makeToggle(p3,"Fly Dron",
    function() SM:Set("FlyDron",true);  MW:StartFlyDron() end,
    function() SM:Set("FlyDron",false); MW:StopFlyDron()  end)
makeSlider(p3,"Dron Height",6,2,30,function(v) MW._dronHeight=v end)

makeToggle(p3,"No Clip",
    function() SM:Set("NoClip",true);  MW:StartNoClip() end,
    function() SM:Set("NoClip",false); MW:StopNoClip()  end)

makeToggle(p3,"Fly Air",
    function() SM:Set("FlyAir",true);  MW:StartFlyAir() end,
    function() SM:Set("FlyAir",false); MW:StopFlyAir()  end)
makeSlider(p3,"Fly Speed",50,10,200,function(v) SM.Params.FlyAirSpeed=v end)

-- Fly Air: nút tăng/giảm độ cao trên màn hình
local flyBtnFrame = Instance.new("Frame")
flyBtnFrame.Size            = UDim2.fromOffset(80,70)
flyBtnFrame.Position        = UDim2.new(1,-90,0.5,-35)
flyBtnFrame.BackgroundTransparency=1
flyBtnFrame.Visible         = false
flyBtnFrame.Parent          = gui

local function makeFlyBtn(txt,y)
    local b=Instance.new("TextButton")
    b.Size=UDim2.fromOffset(70,28); b.Position=UDim2.fromOffset(0,y)
    b.BackgroundColor3=BLACK; b.Text=txt; b.TextColor3=GREEN
    b.Font=Enum.Font.GothamBold; b.TextSize=14; b.BorderSizePixel=0
    local s=Instance.new("UIStroke"); s.Color=GREEN; s.Parent=b
    b.Parent=flyBtnFrame; return b
end
local flyUpBtn  = makeFlyBtn("▲ Lên",0)
local flyDnBtn  = makeFlyBtn("▼ Xuống",36)

flyUpBtn.MouseButton1Down:Connect(function()  MW._flyAirUp=true  end)
flyUpBtn.MouseButton1Up:Connect(function()    MW._flyAirUp=false end)
flyDnBtn.MouseButton1Down:Connect(function()  MW._flyAirDown=true  end)
flyDnBtn.MouseButton1Up:Connect(function()    MW._flyAirDown=false end)

-- Hiện nút khi Fly Air bật
RunService.Heartbeat:Connect(function()
    flyBtnFrame.Visible = SM:Get("FlyAir")
end)

makeToggle(p3,"Speed",
    function()
        SM:Set("SpeedOn",true)
        MW:SetSpeed(SM.Params.WalkSpeed)
    end,
    function()
        SM:Set("SpeedOn",false)
        MW:ResetSpeed()
    end)
makeSlider(p3,"Walk Speed",16,16,200,function(v)
    SM.Params.WalkSpeed=v
    if SM:Get("SpeedOn") then MW:SetSpeed(v) end
end)

makeToggle(p3,"Jumping Air",
    function() SM:Set("JumpAir",true);  MW:StartJumpAir() end,
    function() SM:Set("JumpAir",false); MW:StopJumpAir()  end)

makeToggle(p3,"Night Vision",
    function() SM:Set("NightVision",true);  MW:StartNightVision() end,
    function() SM:Set("NightVision",false); MW:StopNightVision()  end)

makeToggle(p3,"Fix Lag",
    function() SM:Set("FixLag",true);  MW:StartFixLag() end,
    function() SM:Set("FixLag",false); MW:StopFixLag()  end)

--------------------------------------------------------------------------------
-- Dọn dẹp khi character respawn
--------------------------------------------------------------------------------
lp.CharacterAdded:Connect(function()
    -- Tắt fly và noclip để không bị kẹt sau respawn
    SM:Set("FlyAir",false);  MW:StopFlyAir()
    SM:Set("FlyDron",false); MW:StopFlyDron()
    SM:Set("NoClip",false);  MW:StopNoClip()
    SM:Set("FlyDown",false); MW:StopFlyDown()
end)

print("[HpTeamProV1] Đã tải xong.")
