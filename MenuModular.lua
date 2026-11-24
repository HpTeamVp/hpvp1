--[[
    DebugGUI.lua - Hệ thống giao diện debug/test hoàn chỉnh
    Tác giả: Senior Roblox/Luau Engineer
    Kiến trúc: Modular (StateManager, TargetScanner, CombatEngine, EspEngine, MovementAndWorld, UIController)
    Phạm vi mặc định: 150 studs
    
    CÁCH CẮM CƠ CHẾ TẤN CÔNG CỦA GAME:
    Tìm hàm `CombatEngine.AttackHook(target, mode)` ở cuối phần CombatEngine
    và thay thế nội dung bằng logic tấn công/bắn của game bạn.
    Ví dụ: gọi RemoteEvent fireServer, kích hoạt Tool:Activate(), v.v.
]]

-- ============================================================
-- KHỞI TẠO DỊCH VỤ
-- ============================================================
local Players         = game:GetService("Players")
local RunService      = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService    = game:GetService("TweenService")
local Lighting        = game:GetService("Lighting")
local Workspace       = game:GetService("Workspace")
local CoreGui         = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer
local Camera      = Workspace.CurrentCamera

-- Utility: lấy character an toàn
local function GetCharacter()
    return LocalPlayer.Character
end

local function GetRoot()
    local char = GetCharacter()
    return char and (char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart)
end

local function GetHumanoid()
    local char = GetCharacter()
    return char and char:FindFirstChildOfClass("Humanoid")
end

-- ============================================================
-- MODULE: StateManager
-- Quản lý trạng thái ON/OFF và snapshot giá trị gốc
-- ============================================================
local StateManager = {}
StateManager._states    = {}  -- [featureName] = bool
StateManager._snapshots = {}  -- [featureName] = {key=value, ...}
StateManager._configs   = {
    ScanRange        = 150,
    DroneHeightOffset = 12,
    FlySpeed         = 50,
    WalkSpeed        = 16,
    TeleDronSafeHeight = 12,
    FlyAirSpeed      = 50,
    HitboxSize       = Vector3.new(10, 10, 10),
    PlayerBarrierSize = 10,
    ModelBuryDepth   = -5,
    ModelHeadDepth   = -3,
    LongLegsDepth    = -15,
    LongHeadHeight   = 10,
    FlyDronHeight    = 6,
    FlyDownDepth     = -5,
}

-- Bật/tắt tính năng và trả về trạng thái mới
function StateManager:Toggle(feature)
    self._states[feature] = not self._states[feature]
    return self._states[feature]
end

function StateManager:IsOn(feature)
    return self._states[feature] == true
end

function StateManager:SetConfig(key, value)
    self._configs[key] = value
end

function StateManager:GetConfig(key)
    return self._configs[key]
end

-- Lưu snapshot giá trị gốc trước khi bật tính năng
function StateManager:SaveSnapshot(feature, data)
    self._snapshots[feature] = data
end

function StateManager:GetSnapshot(feature)
    return self._snapshots[feature] or {}
end

function StateManager:ClearSnapshot(feature)
    self._snapshots[feature] = nil
end

-- ============================================================
-- MODULE: TargetScanner
-- Quét mục tiêu hợp lệ trong phạm vi 150, cache theo frame
-- ============================================================
local TargetScanner = {}
TargetScanner._cache       = {}
TargetScanner._lastScanTick = 0
TargetScanner._scanInterval = 0.2  -- Quét lại mỗi 0.2 giây để tiết kiệm CPU

-- Kiểm tra model có hợp lệ không
local function IsValidTarget(model)
    if not model or not model.Parent then return false end
    -- Loại trừ chính người chơi
    if model == GetCharacter() then return false end
    -- Loại trừ nhân vật người chơi khác (chỉ lấy NPC/Mob)
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and p.Character == model then return false end
    end
    -- Phải có Humanoid còn sống
    local hum = model:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then return false end
    -- Phải có HumanoidRootPart hoặc PrimaryPart
    local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
    if not root then return false end
    return true
end

-- Lấy vị trí của mục tiêu
function TargetScanner:GetTargetPos(model)
    local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
    return root and root.Position or nil
end

-- Quét tất cả mục tiêu hợp lệ, sắp xếp theo khoảng cách
function TargetScanner:Scan()
    local now = tick()
    if now - self._lastScanTick < self._scanInterval then
        return self._cache
    end
    self._lastScanTick = now

    local playerRoot = GetRoot()
    if not playerRoot then
        self._cache = {}
        return self._cache
    end

    local playerPos = playerRoot.Position
    local range     = StateManager:GetConfig("ScanRange")
    local results   = {}

    -- Quét tất cả model trong Workspace
    for _, obj in ipairs(Workspace:GetDescendants()) do
        if obj:IsA("Model") and IsValidTarget(obj) then
            local targetPos = self:GetTargetPos(obj)
            if targetPos then
                local dist = (targetPos - playerPos).Magnitude
                if dist <= range then
                    table.insert(results, {model = obj, distance = dist, pos = targetPos})
                end
            end
        end
    end

    -- Sắp xếp theo khoảng cách gần nhất
    table.sort(results, function(a, b) return a.distance < b.distance end)
    self._cache = results
    return results
end

-- Lấy mục tiêu gần nhất
function TargetScanner:GetNearest()
    local targets = self:Scan()
    return targets[1] and targets[1].model or nil
end

-- ============================================================
-- MODULE: CombatEngine
-- Xử lý các tính năng combat: TeleDron, TeleKill, Aimbot, v.v.
-- ============================================================
local CombatEngine = {}
CombatEngine._connections  = {}
CombatEngine._lockedTarget = nil
CombatEngine._runLoops     = {}

-- Dừng tất cả loop của một tính năng
local function StopLoop(name)
    if CombatEngine._runLoops[name] then
        CombatEngine._runLoops[name] = false
    end
end

-- Dọn dẹp connection khi tắt tính năng
local function CleanupConnection(name)
    if CombatEngine._connections[name] then
        CombatEngine._connections[name]:Disconnect()
        CombatEngine._connections[name] = nil
    end
end

--[[ 
    AttackHook: HÀM CẮM CƠ CHẾ TẤN CÔNG CỦA GAME
    
    target = Model của mục tiêu
    mode   = string mô tả chế độ ("telekill", "teleDron", v.v.)
    
    CÁCH TÍCH HỢP:
    - Tìm RemoteEvent tấn công của game (ví dụ: game.ReplicatedStorage.Attack)
    - Hoặc kích hoạt Tool đang cầm: LocalPlayer.Character:FindFirstChildOfClass("Tool"):Activate()
    - Hoặc gọi hàm bắn tùy game
    
    Ví dụ tích hợp:
    local attackRemote = game.ReplicatedStorage:FindFirstChild("AttackEvent")
    if attackRemote then
        attackRemote:FireServer(target, mode)
    end
]]
function CombatEngine.AttackHook(target, mode)
    -- === THAY THẾ NỘI DUNG NÀY BẰNG CƠ CHẾ TẤN CÔNG CỦA GAME ===
    -- Mặc định: kích hoạt tool đang cầm nếu có
    local char = GetCharacter()
    if char then
        local tool = char:FindFirstChildOfClass("Tool")
        if tool and tool.Activated then
            -- tool:Activate() -- Bỏ comment nếu game dùng tool chuẩn
        end
    end
    -- Ghi log để debug
    -- print("[AttackHook] Target:", target.Name, "Mode:", mode)
end

-- Khóa mục tiêu và tự chuyển khi mục tiêu chết/mất
function CombatEngine:LockTarget(model)
    self._lockedTarget = model
    -- Theo dõi khi mục tiêu chết hoặc bị xóa
    CleanupConnection("lockWatch")
    if model then
        local hum = model:FindFirstChildOfClass("Humanoid")
        if hum then
            self._connections["lockWatch"] = hum.Died:Connect(function()
                self._lockedTarget = nil
            end)
        end
    end
end

function CombatEngine:GetLockedTarget()
    -- Kiểm tra mục tiêu còn hợp lệ không
    local t = self._lockedTarget
    if t and (not t.Parent or not IsValidTarget(t)) then
        self._lockedTarget = nil
        return nil
    end
    return t
end

-- ==========================================
-- TELE DRON
-- Lơ lửng phía trên mục tiêu và tấn công xuống
-- ==========================================
function CombatEngine:StartTeleDron()
    StopLoop("teleDron")
    self._runLoops["teleDron"] = true

    local safeHeight = StateManager:GetConfig("TeleDronSafeHeight")

    task.spawn(function()
        while self._runLoops["teleDron"] and StateManager:IsOn("TeleDron") do
            local char = GetCharacter()
            local root = GetRoot()
            local hum  = GetHumanoid()
            if char and root and hum then
                -- Lấy mục tiêu gần nhất hoặc mục tiêu đã khóa
                local target = self:GetLockedTarget() or TargetScanner:GetNearest()
                if target then
                    self:LockTarget(target)
                    local targetPos = TargetScanner:GetTargetPos(target)
                    if targetPos then
                        local dronePos = targetPos + Vector3.new(0, safeHeight, 0)
                        -- Dịch chuyển nhân vật tới vị trí drone
                        root.CFrame = CFrame.new(dronePos)
                        -- Triệt tiêu trọng lực bằng cách liên tục reset velocity
                        local bodyVelocity = root:FindFirstChild("_DronBV")
                        if not bodyVelocity then
                            bodyVelocity = Instance.new("BodyVelocity")
                            bodyVelocity.Name = "_DronBV"
                            bodyVelocity.MaxForce = Vector3.new(1e5, 1e5, 1e5)
                            bodyVelocity.Parent = root
                        end
                        bodyVelocity.Velocity = Vector3.zero
                        -- Kích hoạt tấn công hướng xuống
                        self.AttackHook(target, "teleDron")
                    end
                else
                    -- Không có mục tiêu: xóa BodyVelocity nếu có
                    local bv = root:FindFirstChild("_DronBV")
                    if bv then bv:Destroy() end
                end
            end
            task.wait(0.1)
        end
        -- Dọn dẹp khi tắt
        local root = GetRoot()
        if root then
            local bv = root:FindFirstChild("_DronBV")
            if bv then bv:Destroy() end
        end
    end)
end

function CombatEngine:StopTeleDron()
    StopLoop("teleDron")
    local root = GetRoot()
    if root then
        local bv = root:FindFirstChild("_DronBV")
        if bv then bv:Destroy() end
    end
end

-- ==========================================
-- HITBOX ALL MOD
-- Tăng kích thước hitbox của tất cả NPC/Mob
-- ==========================================
function CombatEngine:StartHitboxAllMod()
    StopLoop("hitbox")
    self._runLoops["hitbox"] = true
    local hitboxSize = StateManager:GetConfig("HitboxSize")

    task.spawn(function()
        while self._runLoops["hitbox"] and StateManager:IsOn("HitboxAllMod") do
            local targets = TargetScanner:Scan()
            for _, t in ipairs(targets) do
                local model = t.model
                -- Phóng to tất cả BasePart của model
                for _, part in ipairs(model:GetDescendants()) do
                    if part:IsA("BasePart") then
                        -- Lưu kích thước gốc nếu chưa lưu
                        if not part:FindFirstChild("_OrigSize") then
                            local tag = Instance.new("Vector3Value")
                            tag.Name  = "_OrigSize"
                            tag.Value = part.Size
                            tag.Parent = part
                        end
                        -- Phóng to hitbox
                        part.Size = hitboxSize
                        -- Cho phép xuyên tường và dưới đất
                        part.CanCollide = false
                    end
                end
            end
            task.wait(0.2)
        end
        -- Khôi phục kích thước gốc khi tắt
        for _, t in ipairs(TargetScanner:Scan()) do
            for _, part in ipairs(t.model:GetDescendants()) do
                local origSize = part:FindFirstChild("_OrigSize")
                if origSize then
                    part.Size = origSize.Value
                    part.CanCollide = true
                    origSize:Destroy()
                end
            end
        end
    end)
end

function CombatEngine:StopHitboxAllMod()
    StopLoop("hitbox")
    -- Khôi phục ngay khi tắt
    for _, t in ipairs(TargetScanner._cache) do
        if t.model and t.model.Parent then
            for _, part in ipairs(t.model:GetDescendants()) do
                local origSize = part:FindFirstChild("_OrigSize")
                if origSize then
                    part.Size = origSize.Value
                    part.CanCollide = true
                    origSize:Destroy()
                end
            end
        end
    end
end

-- ==========================================
-- TELE KILL
-- Dịch chuyển tới mob và tấn công liên tục
-- ==========================================
function CombatEngine:StartTeleKill()
    StopLoop("teleKill")
    self._runLoops["teleKill"] = true

    task.spawn(function()
        while self._runLoops["teleKill"] and StateManager:IsOn("TeleKill") do
            local root = GetRoot()
            if root then
                local target = self:GetLockedTarget() or TargetScanner:GetNearest()
                if target then
                    self:LockTarget(target)
                    local targetPos = TargetScanner:GetTargetPos(target)
                    if targetPos then
                        -- Dịch chuyển tới vị trí tối ưu (cách mục tiêu 2 studs)
                        local offset = Vector3.new(2, 0, 0)
                        root.CFrame = CFrame.new(targetPos + offset)
                        -- Kích hoạt tấn công
                        self.AttackHook(target, "teleKill")
                    end
                else
                    -- Không còn mục tiêu: tìm mục tiêu mới
                    self._lockedTarget = nil
                end
            end
            task.wait(0.15)
        end
    end)
end

function CombatEngine:StopTeleKill()
    StopLoop("teleKill")
    self._lockedTarget = nil
end

-- ==========================================
-- AIMBOT
-- Khóa camera vào mục tiêu mượt mà
-- ==========================================
function CombatEngine:StartAimbot()
    CleanupConnection("aimbot")
    self._connections["aimbot"] = RunService.RenderStepped:Connect(function()
        if not StateManager:IsOn("Aimbot") then return end
        local target = self:GetLockedTarget() or TargetScanner:GetNearest()
        if target then
            self:LockTarget(target)
            local targetPos = TargetScanner:GetTargetPos(target)
            if targetPos then
                local root = GetRoot()
                if root then
                    -- Hướng camera mượt mà về phía mục tiêu
                    local direction = (targetPos - Camera.CFrame.Position).Unit
                    local targetCF  = CFrame.lookAt(Camera.CFrame.Position, targetPos)
                    -- Tween mượt mà để chống rung
                    Camera.CFrame = Camera.CFrame:Lerp(targetCF, 0.15)
                end
            end
        end
    end)
end

function CombatEngine:StopAimbot()
    CleanupConnection("aimbot")
    Camera.CameraType = Enum.CameraType.Custom
end

-- ==========================================
-- ALL MOD IM (Immobilize All Mods)
-- Làm tất cả mod đứng yên và không tấn công
-- ==========================================
function CombatEngine:StartAllModIm()
    StopLoop("allModIm")
    self._runLoops["allModIm"] = true

    task.spawn(function()
        while self._runLoops["allModIm"] and StateManager:IsOn("AllModIm") do
            local targets = TargetScanner:Scan()
            for _, t in ipairs(targets) do
                local model = t.model
                local hum   = model:FindFirstChildOfClass("Humanoid")
                if hum then
                    -- Đặt WalkSpeed và JumpPower về 0 để không di chuyển
                    if not model:FindFirstChild("_ImOrig") then
                        local tag = Instance.new("NumberValue")
                        tag.Name   = "_ImOrig"
                        tag.Value  = hum.WalkSpeed
                        tag.Parent = model
                    end
                    hum.WalkSpeed  = 0
                    hum.JumpPower  = 0
                    hum.AutoRotate = false
                    -- Với mob tầm xa: hướng tấn công xuống đất
                    local root = model:FindFirstChild("HumanoidRootPart")
                    if root then
                        root.CFrame = CFrame.new(root.Position) * CFrame.Angles(math.rad(90), 0, 0)
                    end
                end
            end
            task.wait(0.3)
        end
        -- Khôi phục khi tắt
        for _, t in ipairs(TargetScanner._cache) do
            if t.model and t.model.Parent then
                local hum  = t.model:FindFirstChildOfClass("Humanoid")
                local orig = t.model:FindFirstChild("_ImOrig")
                if hum and orig then
                    hum.WalkSpeed  = orig.Value
                    hum.JumpPower  = 50
                    hum.AutoRotate = true
                    orig:Destroy()
                end
            end
        end
    end)
end

function CombatEngine:StopAllModIm()
    StopLoop("allModIm")
    for _, t in ipairs(TargetScanner._cache) do
        if t.model and t.model.Parent then
            local hum  = t.model:FindFirstChildOfClass("Humanoid")
            local orig = t.model:FindFirstChild("_ImOrig")
            if hum and orig then
                hum.WalkSpeed  = orig.Value
                hum.JumpPower  = 50
                hum.AutoRotate = true
                orig:Destroy()
            end
        end
    end
end

-- ==========================================
-- MODEL ĐỘN THỔ (Chôn mod xuống đất)
-- ==========================================
function CombatEngine:StartModelBury()
    StopLoop("modelBury")
    self._runLoops["modelBury"] = true
    local depth = StateManager:GetConfig("ModelBuryDepth")

    task.spawn(function()
        while self._runLoops["modelBury"] and StateManager:IsOn("ModelBury") do
            local targets = TargetScanner:Scan()
            for _, t in ipairs(targets) do
                local model = t.model
                local root  = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
                if root then
                    -- Lưu vị trí gốc
                    if not model:FindFirstChild("_BuryOrig") then
                        local tag = Instance.new("Vector3Value")
                        tag.Name   = "_BuryOrig"
                        tag.Value  = root.Position
                        tag.Parent = model
                    end
                    -- Chôn xuống đất
                    local newY  = root.Position.Y + depth
                    root.CFrame = CFrame.new(root.Position.X, newY, root.Position.Z)
                    -- Vô hiệu hóa tấn công
                    local hum = model:FindFirstChildOfClass("Humanoid")
                    if hum then hum.WalkSpeed = 0 end
                end
            end
            task.wait(0.2)
        end
        -- Khôi phục
        for _, t in ipairs(TargetScanner._cache) do
            if t.model and t.model.Parent then
                local root = t.model:FindFirstChild("HumanoidRootPart") or t.model.PrimaryPart
                local orig = t.model:FindFirstChild("_BuryOrig")
                if root and orig then
                    root.CFrame = CFrame.new(orig.Value)
                    orig:Destroy()
                end
                local hum = t.model:FindFirstChildOfClass("Humanoid")
                if hum then hum.WalkSpeed = 16 end
            end
        end
    end)
end

function CombatEngine:StopModelBury()
    StopLoop("modelBury")
end

-- ==========================================
-- MODEL HEAD DOWN (Cắm đầu vào đất)
-- ==========================================
function CombatEngine:StartModelHeadDown()
    StopLoop("modelHeadDown")
    self._runLoops["modelHeadDown"] = true
    local depth = StateManager:GetConfig("ModelHeadDepth")

    task.spawn(function()
        while self._runLoops["modelHeadDown"] and StateManager:IsOn("ModelHeadDown") do
            local targets = TargetScanner:Scan()
            for _, t in ipairs(targets) do
                local model = t.model
                local root  = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
                if root then
                    -- Lật ngược model (đầu xuống đất)
                    local pos   = root.Position
                    root.CFrame = CFrame.new(pos) * CFrame.Angles(math.pi, 0, 0)
                    root.CFrame = CFrame.new(pos.X, pos.Y + depth, pos.Z) * CFrame.Angles(math.pi, 0, 0)
                    -- Vô hiệu hóa tấn công và không cho bay lên
                    local hum = model:FindFirstChildOfClass("Humanoid")
                    if hum then
                        hum.WalkSpeed = 0
                        hum.JumpPower = 0
                    end
                end
            end
            task.wait(0.2)
        end
        -- Khôi phục
        for _, t in ipairs(TargetScanner._cache) do
            if t.model and t.model.Parent then
                local root = t.model:FindFirstChild("HumanoidRootPart") or t.model.PrimaryPart
                if root then
                    root.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, 0, 0)
                end
                local hum = t.model:FindFirstChildOfClass("Humanoid")
                if hum then
                    hum.WalkSpeed = 16
                    hum.JumpPower = 50
                end
            end
        end
    end)
end

function CombatEngine:StopModelHeadDown()
    StopLoop("modelHeadDown")
end

-- ==========================================
-- PLAYER BARRIER (Rào chắn vô hình)
-- ==========================================
function CombatEngine:StartPlayerBarrier()
    -- Xóa barrier cũ nếu có
    self:StopPlayerBarrier()
    local root = GetRoot()
    if not root then return end

    local barrierSize = StateManager:GetConfig("PlayerBarrierSize")
    -- Tạo barrier là một part trong suốt bao quanh người chơi
    local barrier = Instance.new("Part")
    barrier.Name         = "_PlayerBarrier"
    barrier.Size         = Vector3.new(barrierSize, barrierSize, barrierSize)
    barrier.Transparency = 0.8
    barrier.CanCollide   = true
    barrier.Anchored     = false
    barrier.Material     = Enum.Material.ForceField
    barrier.BrickColor   = BrickColor.new("Bright blue")
    barrier.Parent       = Workspace

    -- Weld barrier vào nhân vật
    local weld = Instance.new("WeldConstraint")
    weld.Part0 = root
    weld.Part1 = barrier
    weld.Parent = barrier

    self._barrierPart = barrier

    -- Liên kết barrier với root
    CleanupConnection("barrierUpdate")
    self._connections["barrierUpdate"] = RunService.Heartbeat:Connect(function()
        if barrier and barrier.Parent then
            barrier.CFrame = root.CFrame
        end
    end)
end

function CombatEngine:StopPlayerBarrier()
    CleanupConnection("barrierUpdate")
    if self._barrierPart and self._barrierPart.Parent then
        self._barrierPart:Destroy()
        self._barrierPart = nil
    end
end

-- ==========================================
-- LONG LEGS (Chân dài xuống lòng đất)
-- ==========================================
function CombatEngine:StartLongLegs()
    StopLoop("longLegs")
    self._runLoops["longLegs"] = true
    local depth = StateManager:GetConfig("LongLegsDepth")

    task.spawn(function()
        while self._runLoops["longLegs"] and StateManager:IsOn("LongLegs") do
            local targets = TargetScanner:Scan()
            for _, t in ipairs(targets) do
                local model = t.model
                -- Kéo dài chân (LeftLeg, RightLeg hoặc LowerTorso)
                for _, limb in ipairs({"LeftLeg", "RightLeg", "LeftLowerLeg", "RightLowerLeg"}) do
                    local part = model:FindFirstChild(limb)
                    if part and part:IsA("BasePart") then
                        if not part:FindFirstChild("_LLOrig") then
                            local tag = Instance.new("Vector3Value")
                            tag.Name   = "_LLOrig"
                            tag.Value  = part.Size
                            tag.Parent = part
                        end
                        -- Kéo dài chân xuống
                        part.Size = Vector3.new(part.Size.X, math.abs(depth), part.Size.Z)
                        part.CFrame = CFrame.new(part.Position.X, part.Position.Y + depth/2, part.Position.Z)
                        part.CanCollide = true
                    end
                end
            end
            task.wait(0.3)
        end
        -- Khôi phục
        for _, t in ipairs(TargetScanner._cache) do
            if t.model and t.model.Parent then
                for _, limb in ipairs({"LeftLeg", "RightLeg", "LeftLowerLeg", "RightLowerLeg"}) do
                    local part = t.model:FindFirstChild(limb)
                    if part then
                        local orig = part:FindFirstChild("_LLOrig")
                        if orig then
                            part.Size = orig.Value
                            orig:Destroy()
                        end
                    end
                end
            end
        end
    end)
end

function CombatEngine:StopLongLegs()
    StopLoop("longLegs")
end

-- ==========================================
-- LONG HEAD (Đầu to dài lên trên)
-- ==========================================
function CombatEngine:StartLongHead()
    StopLoop("longHead")
    self._runLoops["longHead"] = true
    local headHeight = StateManager:GetConfig("LongHeadHeight")

    task.spawn(function()
        while self._runLoops["longHead"] and StateManager:IsOn("LongHead") do
            local targets = TargetScanner:Scan()
            for _, t in ipairs(targets) do
                local model = t.model
                local head  = model:FindFirstChild("Head")
                if head and head:IsA("BasePart") then
                    if not head:FindFirstChild("_LHOrig") then
                        local tag = Instance.new("Vector3Value")
                        tag.Name   = "_LHOrig"
                        tag.Value  = head.Size
                        tag.Parent = head
                    end
                    head.Size   = Vector3.new(head.Size.X * 2, headHeight, head.Size.Z * 2)
                end
            end
            task.wait(0.3)
        end
        for _, t in ipairs(TargetScanner._cache) do
            if t.model and t.model.Parent then
                local head = t.model:FindFirstChild("Head")
                if head then
                    local orig = head:FindFirstChild("_LHOrig")
                    if orig then
                        head.Size = orig.Value
                        orig:Destroy()
                    end
                end
            end
        end
    end)
end

function CombatEngine:StopLongHead()
    StopLoop("longHead")
end

-- ============================================================
-- MODULE: EspEngine
-- Vẽ ESP: Line, Box, Name, Distance, Hologram
-- ============================================================
local EspEngine = {}
EspEngine._drawings    = {}  -- [model] = {line, box, nameLabel, distLabel}
EspEngine._highlights  = {}  -- [model] = Highlight
EspEngine._connections = {}

-- Tạo đối tượng vẽ 2D (dùng Drawing API nếu có, fallback sang ScreenGui)
local function CreateDrawing(type_, props)
    -- Thử dùng Drawing API (executor phổ biến như Synapse, KRNL)
    local ok, drawing = pcall(function()
        local d = Drawing.new(type_)
        for k, v in pairs(props) do
            d[k] = v
        end
        return d
    end)
    if ok then return drawing end
    return nil
end

-- Chuyển đổi vị trí 3D sang 2D màn hình
local function WorldToScreen(worldPos)
    local screenPos, onScreen = Camera:WorldToViewportPoint(worldPos)
    return Vector2.new(screenPos.X, screenPos.Y), onScreen, screenPos.Z
end

-- Lấy bounding box 2D của model
local function GetModelBounds2D(model)
    local minX, minY =  math.huge,  math.huge
    local maxX, maxY = -math.huge, -math.huge
    local anyOnScreen = false

    for _, part in ipairs(model:GetDescendants()) do
        if part:IsA("BasePart") then
            local corners = {
                part.Position + Vector3.new( part.Size.X/2,  part.Size.Y/2,  part.Size.Z/2),
                part.Position + Vector3.new(-part.Size.X/2,  part.Size.Y/2,  part.Size.Z/2),
                part.Position + Vector3.new( part.Size.X/2, -part.Size.Y/2,  part.Size.Z/2),
                part.Position + Vector3.new( part.Size.X/2,  part.Size.Y/2, -part.Size.Z/2),
                part.Position + Vector3.new(-part.Size.X/2, -part.Size.Y/2, -part.Size.Z/2),
            }
            for _, corner in ipairs(corners) do
                local screen, onScreen = WorldToScreen(corner)
                if onScreen then
                    anyOnScreen = true
                    minX = math.min(minX, screen.X)
                    minY = math.min(minY, screen.Y)
                    maxX = math.max(maxX, screen.X)
                    maxY = math.max(maxY, screen.Y)
                end
            end
        end
    end

    return anyOnScreen, minX, minY, maxX, maxY
end

-- Dọn dẹp ESP của một mục tiêu cụ thể
function EspEngine:CleanupTarget(model)
    local d = self._drawings[model]
    if d then
        if d.line   and d.line.Remove   then d.line:Remove()   end
        if d.box    and d.box.Remove    then d.box:Remove()    end
        if d.nameL  and d.nameL.Remove  then d.nameL:Remove()  end
        if d.distL  and d.distL.Remove  then d.distL:Remove()  end
        self._drawings[model] = nil
    end
    local h = self._highlights[model]
    if h then
        h:Destroy()
        self._highlights[model] = nil
    end
end

-- Dọn dẹp toàn bộ ESP
function EspEngine:CleanupAll()
    for model, _ in pairs(self._drawings) do
        self:CleanupTarget(model)
    end
    for model, h in pairs(self._highlights) do
        h:Destroy()
    end
    self._highlights = {}
    self._drawings   = {}
    for name, conn in pairs(self._connections) do
        conn:Disconnect()
    end
    self._connections = {}
end

-- Khởi động vòng lặp cập nhật ESP
function EspEngine:StartLoop()
    if self._connections["loop"] then return end

    self._connections["loop"] = RunService.RenderStepped:Connect(function()
        local root      = GetRoot()
        if not root then return end
        local playerPos = root.Position
        local range     = StateManager:GetConfig("ScanRange")
        local targets   = TargetScanner:Scan()

        -- Tạo set mục tiêu hiện tại để so sánh
        local currentSet = {}
        for _, t in ipairs(targets) do
            currentSet[t.model] = true
        end

        -- Xóa mục tiêu không còn hợp lệ
        for model, _ in pairs(self._drawings) do
            if not currentSet[model] then
                self:CleanupTarget(model)
            end
        end
        for model, _ in pairs(self._highlights) do
            if not currentSet[model] then
                self:CleanupTarget(model)
            end
        end

        -- Cập nhật/vẽ cho từng mục tiêu hợp lệ
        for _, t in ipairs(targets) do
            local model = t.model

            -- Khởi tạo entry nếu chưa có
            if not self._drawings[model] then
                self._drawings[model] = {}
            end
            local d = self._drawings[model]

            local targetPos    = TargetScanner:GetTargetPos(model)
            if not targetPos then continue end
            local dist         = t.distance
            local screenPos, onScreen = WorldToScreen(targetPos)

            -- === ESP LINE ===
            if StateManager:IsOn("EspLine") then
                local vpSize = Camera.ViewportSize
                local top    = Vector2.new(vpSize.X / 2, 0)
                if not d.line then
                    d.line = CreateDrawing("Line", {
                        Thickness = 1,
                        Color     = Color3.fromRGB(255, 100, 100),
                        Transparency = 1,
                        Visible   = false,
                    })
                end
                if d.line then
                    d.line.From    = top
                    d.line.To      = screenPos
                    d.line.Visible = onScreen
                end
            elseif d.line then
                d.line.Visible = false
            end

            -- === ESP BOX ===
            if StateManager:IsOn("EspBox") then
                local anyOn, x1, y1, x2, y2 = GetModelBounds2D(model)
                if not d.box then
                    d.box = CreateDrawing("Square", {
                        Thickness    = 1,
                        Color        = Color3.fromRGB(255, 255, 0),
                        Filled       = false,
                        Transparency = 1,
                        Visible      = false,
                    })
                end
                if d.box and anyOn then
                    d.box.Position = Vector2.new(x1, y1)
                    d.box.Size     = Vector2.new(x2 - x1, y2 - y1)
                    d.box.Visible  = true
                elseif d.box then
                    d.box.Visible = false
                end
            elseif d.box then
                d.box.Visible = false
            end

            -- === ESP NAME ===
            if StateManager:IsOn("EspName") then
                if not d.nameL then
                    d.nameL = CreateDrawing("Text", {
                        Size      = 14,
                        Color     = Color3.fromRGB(255, 255, 255),
                        Outline   = true,
                        Center    = true,
                        Visible   = false,
                    })
                end
                if d.nameL then
                    d.nameL.Text    = model.Name
                    d.nameL.Position = Vector2.new(screenPos.X, screenPos.Y - 20)
                    d.nameL.Visible  = onScreen
                end
            elseif d.nameL then
                d.nameL.Visible = false
            end

            -- === ESP DISTANCE ===
            if StateManager:IsOn("EspDistance") then
                if not d.distL then
                    d.distL = CreateDrawing("Text", {
                        Size    = 12,
                        Color   = Color3.fromRGB(100, 255, 100),
                        Outline = true,
                        Center  = true,
                        Visible = false,
                    })
                end
                if d.distL then
                    d.distL.Text     = string.format("%.0f studs", dist)
                    d.distL.Position = Vector2.new(screenPos.X, screenPos.Y + 10)
                    d.distL.Visible  = onScreen
                end
            elseif d.distL then
                d.distL.Visible = false
            end

            -- === ESP HOLOGRAM (Highlight xuyên tường) ===
            if StateManager:IsOn("EspHologram") then
                if not self._highlights[model] then
                    local hl = Instance.new("Highlight")
                    hl.FillColor      = Color3.fromRGB(255, 50, 50)
                    hl.OutlineColor   = Color3.fromRGB(255, 255, 255)
                    hl.FillTransparency    = 0.5
                    hl.OutlineTransparency = 0
                    hl.DepthMode      = Enum.HighlightDepthMode.AlwaysOnTop
                    hl.Adornee        = model
                    hl.Parent         = model
                    self._highlights[model] = hl
                end
            elseif self._highlights[model] then
                self._highlights[model]:Destroy()
                self._highlights[model] = nil
            end
        end
    end)
end

function EspEngine:StopLoop()
    if self._connections["loop"] then
        self._connections["loop"]:Disconnect()
        self._connections["loop"] = nil
    end
    self:CleanupAll()
end

-- ============================================================
-- MODULE: MovementAndWorld
-- Fly Down, Fly Dron, No Clip, Fly Air, Speed, Night Vision, Fix Lag
-- ============================================================
local MovementAndWorld = {}
MovementAndWorld._connections = {}
MovementAndWorld._runLoops    = {}
MovementAndWorld._snapshots   = {}

local function StopMoveLoop(name)
    MovementAndWorld._runLoops[name] = false
end

local function CleanMoveConn(name)
    if MovementAndWorld._connections[name] then
        MovementAndWorld._connections[name]:Disconnect()
        MovementAndWorld._connections[name] = nil
    end
end

-- ==========================================
-- FLY DOWN (Nằm ngửa, hạ xuống đất)
-- ==========================================
function MovementAndWorld:StartFlyDown()
    StopMoveLoop("flyDown")
    self._runLoops["flyDown"] = true
    local depth = StateManager:GetConfig("FlyDownDepth")

    task.spawn(function()
        while self._runLoops["flyDown"] and StateManager:IsOn("FlyDown") do
            local char = GetCharacter()
            local root = GetRoot()
            local hum  = GetHumanoid()
            if char and root and hum then
                -- Nằm ngửa (xoay 90 độ quanh Z)
                local pos = root.Position
                root.CFrame = CFrame.new(pos.X, pos.Y + depth, pos.Z) * CFrame.Angles(math.rad(90), 0, 0)

                -- Triệt tiêu trọng lực (BodyVelocity)
                local bv = root:FindFirstChild("_FlyDownBV")
                if not bv then
                    bv = Instance.new("BodyVelocity")
                    bv.Name       = "_FlyDownBV"
                    bv.MaxForce   = Vector3.new(1e5, 1e5, 1e5)
                    bv.Velocity   = Vector3.zero
                    bv.Parent     = root
                end

                -- Điều khiển lên/xuống bằng phím
                local moveDir = Vector3.zero
                if UserInputService:IsKeyDown(Enum.KeyCode.E) then
                    moveDir = Vector3.new(0, 1, 0)
                elseif UserInputService:IsKeyDown(Enum.KeyCode.Q) then
                    moveDir = Vector3.new(0, -1, 0)
                end
                bv.Velocity = moveDir * StateManager:GetConfig("FlySpeed")
            end
            task.wait(0.03)
        end
        -- Dọn dẹp
        local root = GetRoot()
        if root then
            local bv = root:FindFirstChild("_FlyDownBV")
            if bv then bv:Destroy() end
        end
    end)
end

function MovementAndWorld:StopFlyDown()
    StopMoveLoop("flyDown")
    local root = GetRoot()
    if root then
        local bv = root:FindFirstChild("_FlyDownBV")
        if bv then bv:Destroy() end
    end
    -- Khôi phục tư thế nhân vật
    local hum = GetHumanoid()
    if hum then
        -- Reset character
        local char = GetCharacter()
        if char then
            local torso = char:FindFirstChild("HumanoidRootPart")
            if torso then
                torso.CFrame = CFrame.new(torso.Position)
            end
        end
    end
end

-- ==========================================
-- FLY DRON (Bay ở độ cao cố định, mặt úp xuống)
-- ==========================================
function MovementAndWorld:StartFlyDron()
    StopMoveLoop("flyDron")
    self._runLoops["flyDron"] = true
    local height = StateManager:GetConfig("FlyDronHeight")

    task.spawn(function()
        while self._runLoops["flyDron"] and StateManager:IsOn("FlyDron") do
            local root = GetRoot()
            if root then
                local pos = root.Position
                -- Giữ ở độ cao cố định, mặt úp xuống
                local bv = root:FindFirstChild("_FlyDronBV")
                if not bv then
                    bv = Instance.new("BodyVelocity")
                    bv.Name     = "_FlyDronBV"
                    bv.MaxForce = Vector3.new(1e5, 1e5, 1e5)
                    bv.Velocity = Vector3.zero
                    bv.Parent   = root
                end

                -- Giữ độ cao và úp mặt xuống
                local moveDir = Vector3.zero
                local spd     = StateManager:GetConfig("FlySpeed")

                -- Điều khiển lên/xuống
                if UserInputService:IsKeyDown(Enum.KeyCode.E) then
                    moveDir = moveDir + Vector3.new(0, spd, 0)
                    StateManager:SetConfig("FlyDronHeight", height + 0.1)
                    height = StateManager:GetConfig("FlyDronHeight")
                elseif UserInputService:IsKeyDown(Enum.KeyCode.Q) then
                    moveDir = moveDir + Vector3.new(0, -spd, 0)
                    StateManager:SetConfig("FlyDronHeight", math.max(0, height - 0.1))
                    height = StateManager:GetConfig("FlyDronHeight")
                end

                bv.Velocity = moveDir

                -- Tư thế úp mặt xuống
                root.CFrame = CFrame.new(pos) * CFrame.Angles(math.pi, 0, 0)
            end
            task.wait(0.03)
        end
        local root = GetRoot()
        if root then
            local bv = root:FindFirstChild("_FlyDronBV")
            if bv then bv:Destroy() end
        end
    end)
end

function MovementAndWorld:StopFlyDron()
    StopMoveLoop("flyDron")
    local root = GetRoot()
    if root then
        local bv = root:FindFirstChild("_FlyDronBV")
        if bv then bv:Destroy() end
    end
end

-- ==========================================
-- NO CLIP
-- ==========================================
function MovementAndWorld:StartNoClip()
    CleanMoveConn("noClip")
    local char = GetCharacter()
    if not char then return end

    -- Lưu trạng thái CanCollide gốc
    local origCollide = {}
    for _, part in ipairs(char:GetDescendants()) do
        if part:IsA("BasePart") then
            origCollide[part] = part.CanCollide
            part.CanCollide   = false
        end
    end
    self._snapshots["noClip"] = origCollide

    -- Giữ NoClip mỗi frame vì game có thể reset
    self._connections["noClip"] = RunService.Stepped:Connect(function()
        if not StateManager:IsOn("NoClip") then return end
        local c = GetCharacter()
        if c then
            for _, part in ipairs(c:GetDescendants()) do
                if part:IsA("BasePart") then
                    part.CanCollide = false
                end
            end
        end
    end)
end

function MovementAndWorld:StopNoClip()
    CleanMoveConn("noClip")
    -- Khôi phục CanCollide gốc
    local snap = self._snapshots["noClip"] or {}
    for part, orig in pairs(snap) do
        if part and part.Parent then
            part.CanCollide = orig
        end
    end
    self._snapshots["noClip"] = nil
end

-- ==========================================
-- FLY AIR (Bay trên không, giữ vị trí khi đứng yên)
-- ==========================================
function MovementAndWorld:StartFlyAir()
    StopMoveLoop("flyAir")
    self._runLoops["flyAir"] = true

    task.spawn(function()
        while self._runLoops["flyAir"] and StateManager:IsOn("FlyAir") do
            local root = GetRoot()
            local hum  = GetHumanoid()
            if root and hum then
                local spd = StateManager:GetConfig("FlyAirSpeed")

                -- Tính hướng di chuyển theo camera
                local camCF   = Camera.CFrame
                local moveVec = Vector3.zero

                if UserInputService:IsKeyDown(Enum.KeyCode.W) then
                    moveVec = moveVec + camCF.LookVector
                end
                if UserInputService:IsKeyDown(Enum.KeyCode.S) then
                    moveVec = moveVec - camCF.LookVector
                end
                if UserInputService:IsKeyDown(Enum.KeyCode.A) then
                    moveVec = moveVec - camCF.RightVector
                end
                if UserInputService:IsKeyDown(Enum.KeyCode.D) then
                    moveVec = moveVec + camCF.RightVector
                end
                if UserInputService:IsKeyDown(Enum.KeyCode.E) then
                    moveVec = moveVec + Vector3.new(0, 1, 0)
                end
                if UserInputService:IsKeyDown(Enum.KeyCode.Q) then
                    moveVec = moveVec - Vector3.new(0, 1, 0)
                end

                -- Tạo hoặc cập nhật BodyVelocity
                local bv = root:FindFirstChild("_FlyAirBV")
                if not bv then
                    bv = Instance.new("BodyVelocity")
                    bv.Name     = "_FlyAirBV"
                    bv.MaxForce = Vector3.new(1e5, 1e5, 1e5)
                    bv.Parent   = root
                end

                -- Giữ vị trí khi không nhấn phím (velocity = 0)
                if moveVec.Magnitude > 0 then
                    bv.Velocity = moveVec.Unit * spd
                else
                    bv.Velocity = Vector3.zero
                end

                -- Vô hiệu hóa trọng lực của Humanoid
                hum.PlatformStand = true
            end
            task.wait(0.03)
        end

        -- Khôi phục
        local root = GetRoot()
        local hum  = GetHumanoid()
        if root then
            local bv = root:FindFirstChild("_FlyAirBV")
            if bv then bv:Destroy() end
        end
        if hum then
            hum.PlatformStand = false
        end
    end)
end

function MovementAndWorld:StopFlyAir()
    StopMoveLoop("flyAir")
    local root = GetRoot()
    local hum  = GetHumanoid()
    if root then
        local bv = root:FindFirstChild("_FlyAirBV")
        if bv then bv:Destroy() end
    end
    if hum then hum.PlatformStand = false end
end

-- ==========================================
-- SPEED (WalkSpeed tùy chỉnh)
-- ==========================================
function MovementAndWorld:StartSpeed()
    local hum = GetHumanoid()
    if not hum then return end
    -- Lưu tốc độ gốc
    if not self._snapshots["speed"] then
        self._snapshots["speed"] = {WalkSpeed = hum.WalkSpeed}
    end
    -- Áp dụng tốc độ mới
    hum.WalkSpeed = StateManager:GetConfig("WalkSpeed")

    -- Theo dõi thay đổi nhân vật để áp dụng lại
    CleanMoveConn("speedWatch")
    self._connections["speedWatch"] = RunService.Heartbeat:Connect(function()
        if not StateManager:IsOn("Speed") then return end
        local h = GetHumanoid()
        if h then h.WalkSpeed = StateManager:GetConfig("WalkSpeed") end
    end)
end

function MovementAndWorld:StopSpeed()
    CleanMoveConn("speedWatch")
    local hum  = GetHumanoid()
    local snap = self._snapshots["speed"]
    if hum and snap then
        hum.WalkSpeed = snap.WalkSpeed
    end
    self._snapshots["speed"] = nil
end

-- ==========================================
-- JUMPING AIR (Nhảy trên không)
-- ==========================================
function MovementAndWorld:StartJumpingAir()
    CleanMoveConn("jumpAir")
    self._connections["jumpAir"] = UserInputService.JumpRequest:Connect(function()
        if not StateManager:IsOn("JumpingAir") then return end
        local hum = GetHumanoid()
        if hum then
            -- Cho phép nhảy khi đang trên không
            local prevState = hum:GetState()
            hum:ChangeState(Enum.HumanoidStateType.Jumping)
            task.wait(0.1)
            -- Giải phóng trạng thái để không bị kẹt
            if hum:GetState() == Enum.HumanoidStateType.Jumping then
                hum:ChangeState(Enum.HumanoidStateType.FreeFall)
            end
        end
    end)
end

function MovementAndWorld:StopJumpingAir()
    CleanMoveConn("jumpAir")
end

-- ==========================================
-- NIGHT VISION
-- ==========================================
function MovementAndWorld:StartNightVision()
    -- Lưu cấu hình ánh sáng gốc
    if not self._snapshots["nightVision"] then
        self._snapshots["nightVision"] = {
            Ambient         = Lighting.Ambient,
            OutdoorAmbient  = Lighting.OutdoorAmbient,
            Brightness      = Lighting.Brightness,
            FogEnd          = Lighting.FogEnd,
            FogStart        = Lighting.FogStart,
        }
    end
    -- Tắt bóng tối và sương mù
    Lighting.Ambient        = Color3.fromRGB(255, 255, 255)
    Lighting.OutdoorAmbient = Color3.fromRGB(255, 255, 255)
    Lighting.Brightness     = 2
    Lighting.FogEnd         = 100000
    Lighting.FogStart       = 100000

    -- Tắt các hiệu ứng hậu kỳ của Lighting
    for _, effect in ipairs(Lighting:GetChildren()) do
        if effect:IsA("BlurEffect") or effect:IsA("ColorCorrectionEffect") or effect:IsA("DepthOfFieldEffect") then
            if not effect:FindFirstChild("_NVOrig") then
                local tag = Instance.new("BoolValue")
                tag.Name   = "_NVOrig"
                tag.Value  = effect.Enabled
                tag.Parent = effect
            end
            effect.Enabled = false
        end
    end
end

function MovementAndWorld:StopNightVision()
    local snap = self._snapshots["nightVision"]
    if snap then
        Lighting.Ambient        = snap.Ambient
        Lighting.OutdoorAmbient = snap.OutdoorAmbient
        Lighting.Brightness     = snap.Brightness
        Lighting.FogEnd         = snap.FogEnd
        Lighting.FogStart       = snap.FogStart
        self._snapshots["nightVision"] = nil
    end
    -- Khôi phục hiệu ứng
    for _, effect in ipairs(Lighting:GetChildren()) do
        local orig = effect:FindFirstChild("_NVOrig")
        if orig then
            effect.Enabled = orig.Value
            orig:Destroy()
        end
    end
end

-- ==========================================
-- FIX LAG (Giảm tải đồ họa)
-- ==========================================
function MovementAndWorld:StartFixLag()
    if not self._snapshots["fixLag"] then
        self._snapshots["fixLag"] = {
            ShadowSoftness = Lighting.ShadowSoftness,
        }
    end

    -- Giảm chất lượng đổ bóng
    Lighting.ShadowSoftness = 0

    -- Xóa các hiệu ứng nặng: Particle, Beam, Trail, v.v.
    for _, obj in ipairs(Workspace:GetDescendants()) do
        if obj:IsA("ParticleEmitter") or obj:IsA("Trail") or obj:IsA("Beam") then
            if not obj:FindFirstChild("_FLHide") then
                local tag = Instance.new("BoolValue")
                tag.Name   = "_FLHide"
                tag.Value  = obj.Enabled
                tag.Parent = obj
            end
            if obj:IsA("ParticleEmitter") then
                obj.Enabled = false
            elseif obj:IsA("Trail") then
                obj.Enabled = false
            end
        end

        -- Giảm texture chất lượng thấp
        if obj:IsA("SpecialMesh") then
            if not obj:FindFirstChild("_FLMesh") then
                local tag = Instance.new("StringValue")
                tag.Name   = "_FLMesh"
                tag.Value  = obj.MeshType.Name
                tag.Parent = obj
            end
        end
    end

    -- Tắt BlurEffect và DepthOfField
    for _, effect in ipairs(Lighting:GetChildren()) do
        if effect:IsA("BlurEffect") or effect:IsA("DepthOfFieldEffect") or effect:IsA("SunRaysEffect") then
            if not effect:FindFirstChild("_FLEff") then
                local tag = Instance.new("BoolValue")
                tag.Name   = "_FLEff"
                tag.Value  = effect.Enabled
                tag.Parent = effect
            end
            effect.Enabled = false
        end
    end
end

function MovementAndWorld:StopFixLag()
    local snap = self._snapshots["fixLag"]
    if snap then
        Lighting.ShadowSoftness = snap.ShadowSoftness
        self._snapshots["fixLag"] = nil
    end

    -- Khôi phục hiệu ứng
    for _, obj in ipairs(Workspace:GetDescendants()) do
        local tag = obj:FindFirstChild("_FLHide")
        if tag then
            if obj:IsA("ParticleEmitter") or obj:IsA("Trail") then
                obj.Enabled = tag.Value
            end
            tag:Destroy()
        end
    end
    for _, effect in ipairs(Lighting:GetChildren()) do
        local tag = effect:FindFirstChild("_FLEff")
        if tag then
            effect.Enabled = tag.Value
            tag:Destroy()
        end
    end
end

-- ============================================================
-- MODULE: UIController
-- Giao diện kéo thả, 3 tab: Main / Esp / Khác
-- ============================================================
local UIController = {}

-- Xóa GUI cũ nếu chạy lại script
if CoreGui:FindFirstChild("DebugGUI_Main") then
    CoreGui:FindFirstChild("DebugGUI_Main"):Destroy()
end

-- Tạo ScreenGui chính
local ScreenGui     = Instance.new("ScreenGui")
ScreenGui.Name      = "DebugGUI_Main"
ScreenGui.ResetOnSpawn = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.Parent    = CoreGui

-- ==========================================
-- FRAME CHÍNH (kéo thả được)
-- ==========================================
local MainFrame = Instance.new("Frame")
MainFrame.Name            = "MainFrame"
MainFrame.Size            = UDim2.new(0, 300, 0, 460)
MainFrame.Position        = UDim2.new(0, 10, 0, 10)
MainFrame.BackgroundColor3 = Color3.fromRGB(18, 18, 24)
MainFrame.BorderSizePixel = 0
MainFrame.ClipsDescendants = false
MainFrame.Parent          = ScreenGui

-- Bo góc
local mainCorner = Instance.new("UICorner")
mainCorner.CornerRadius = UDim.new(0, 8)
mainCorner.Parent = MainFrame

-- Viền
local mainStroke = Instance.new("UIStroke")
mainStroke.Color     = Color3.fromRGB(80, 80, 180)
mainStroke.Thickness = 1.5
mainStroke.Parent    = MainFrame

-- ==========================================
-- THANH TIÊU ĐỀ (kéo thả)
-- ==========================================
local TitleBar = Instance.new("Frame")
TitleBar.Name              = "TitleBar"
TitleBar.Size              = UDim2.new(1, 0, 0, 32)
TitleBar.BackgroundColor3  = Color3.fromRGB(40, 40, 80)
TitleBar.BorderSizePixel   = 0
TitleBar.Parent            = MainFrame

local titleCorner = Instance.new("UICorner")
titleCorner.CornerRadius = UDim.new(0, 8)
titleCorner.Parent = TitleBar

local TitleLabel = Instance.new("TextLabel")
TitleLabel.Text             = "🎮 DebugGUI v1.0"
TitleLabel.Size             = UDim2.new(1, -60, 1, 0)
TitleLabel.Position         = UDim2.new(0, 8, 0, 0)
TitleLabel.BackgroundTransparency = 1
TitleLabel.TextColor3       = Color3.fromRGB(220, 220, 255)
TitleLabel.TextSize         = 14
TitleLabel.Font             = Enum.Font.GothamBold
TitleLabel.TextXAlignment   = Enum.TextXAlignment.Left
TitleLabel.Parent           = TitleBar

-- Nút thu gọn
local CollapseBtn = Instance.new("TextButton")
CollapseBtn.Text             = "−"
CollapseBtn.Size             = UDim2.new(0, 28, 0, 22)
CollapseBtn.Position         = UDim2.new(1, -58, 0, 5)
CollapseBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 100)
CollapseBtn.TextColor3       = Color3.fromRGB(255, 255, 255)
CollapseBtn.Font             = Enum.Font.GothamBold
CollapseBtn.TextSize         = 16
CollapseBtn.BorderSizePixel  = 0
CollapseBtn.Parent           = TitleBar

local collapseCorner = Instance.new("UICorner")
collapseCorner.CornerRadius = UDim.new(0, 4)
collapseCorner.Parent = CollapseBtn

-- Nút đóng
local CloseBtn = Instance.new("TextButton")
CloseBtn.Text             = "✕"
CloseBtn.Size             = UDim2.new(0, 24, 0, 22)
CloseBtn.Position         = UDim2.new(1, -28, 0, 5)
CloseBtn.BackgroundColor3 = Color3.fromRGB(180, 40, 40)
CloseBtn.TextColor3       = Color3.fromRGB(255, 255, 255)
CloseBtn.Font             = Enum.Font.GothamBold
CloseBtn.TextSize         = 13
CloseBtn.BorderSizePixel  = 0
CloseBtn.Parent           = TitleBar

local closeCorner = Instance.new("UICorner")
closeCorner.CornerRadius = UDim.new(0, 4)
closeCorner.Parent = CloseBtn

-- ==========================================
-- LOGIC KÉO THẢ
-- ==========================================
local dragging = false
local dragStart, startPos

TitleBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging  = true
        dragStart = input.Position
        startPos  = MainFrame.Position
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
        local delta = input.Position - dragStart
        MainFrame.Position = UDim2.new(
            startPos.X.Scale,
            startPos.X.Offset + delta.X,
            startPos.Y.Scale,
            startPos.Y.Offset + delta.Y
        )
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging = false
    end
end)

-- Thu gọn/mở rộng
local collapsed    = false
local contentFrame -- được định nghĩa bên dưới

CollapseBtn.MouseButton1Click:Connect(function()
    collapsed = not collapsed
    if collapsed then
        MainFrame.Size    = UDim2.new(0, 300, 0, 32)
        CollapseBtn.Text  = "+"
    else
        MainFrame.Size    = UDim2.new(0, 300, 0, 460)
        CollapseBtn.Text  = "−"
    end
end)

CloseBtn.MouseButton1Click:Connect(function()
    ScreenGui:Destroy()
    EspEngine:StopLoop()
end)

-- ==========================================
-- THANH TAB
-- ==========================================
local TabBar = Instance.new("Frame")
TabBar.Name             = "TabBar"
TabBar.Size             = UDim2.new(1, 0, 0, 30)
TabBar.Position         = UDim2.new(0, 0, 0, 32)
TabBar.BackgroundColor3 = Color3.fromRGB(25, 25, 40)
TabBar.BorderSizePixel  = 0
TabBar.Parent           = MainFrame

local TabLayout = Instance.new("UIListLayout")
TabLayout.FillDirection = Enum.FillDirection.Horizontal
TabLayout.SortOrder     = Enum.SortOrder.LayoutOrder
TabLayout.Parent        = TabBar

local tabNames   = {"Main", "Esp", "Khác"}
local tabButtons = {}
local tabPanels  = {}
local activeTab  = "Main"

-- ==========================================
-- VÙNG NỘI DUNG (cuộn được)
-- ==========================================
local ContentArea = Instance.new("Frame")
ContentArea.Name             = "ContentArea"
ContentArea.Size             = UDim2.new(1, 0, 1, -62)
ContentArea.Position         = UDim2.new(0, 0, 0, 62)
ContentArea.BackgroundTransparency = 1
ContentArea.ClipsDescendants = true
ContentArea.Parent           = MainFrame

-- Tạo từng panel tab (ScrollingFrame)
for _, name in ipairs(tabNames) do
    local panel = Instance.new("ScrollingFrame")
    panel.Name                   = "Panel_" .. name
    panel.Size                   = UDim2.new(1, 0, 1, 0)
    panel.Position               = UDim2.new(0, 0, 0, 0)
    panel.BackgroundTransparency = 1
    panel.BorderSizePixel        = 0
    panel.ScrollBarThickness     = 4
    panel.ScrollBarImageColor3   = Color3.fromRGB(80, 80, 180)
    panel.CanvasSize             = UDim2.new(0, 0, 0, 0)
    panel.AutomaticCanvasSize    = Enum.AutomaticSize.Y
    panel.Visible                = (name == "Main")
    panel.Parent                 = ContentArea
    tabPanels[name] = panel

    local listLayout = Instance.new("UIListLayout")
    listLayout.SortOrder    = Enum.SortOrder.LayoutOrder
    listLayout.Padding      = UDim.new(0, 4)
    listLayout.Parent       = panel

    local padding = Instance.new("UIPadding")
    padding.PaddingLeft   = UDim.new(0, 6)
    padding.PaddingRight  = UDim.new(0, 6)
    padding.PaddingTop    = UDim.new(0, 6)
    padding.Parent        = panel
end

-- Tạo nút tab
for i, name in ipairs(tabNames) do
    local btn = Instance.new("TextButton")
    btn.Text             = name
    btn.Size             = UDim2.new(0, 94, 1, 0)
    btn.LayoutOrder      = i
    btn.BackgroundColor3 = (name == "Main") and Color3.fromRGB(60, 60, 150) or Color3.fromRGB(30, 30, 50)
    btn.TextColor3       = Color3.fromRGB(220, 220, 255)
    btn.Font             = Enum.Font.GothamMedium
    btn.TextSize         = 13
    btn.BorderSizePixel  = 0
    btn.Parent           = TabBar
    tabButtons[name]     = btn

    btn.MouseButton1Click:Connect(function()
        activeTab = name
        for _, n in ipairs(tabNames) do
            tabPanels[n].Visible   = (n == name)
            tabButtons[n].BackgroundColor3 = (n == name)
                and Color3.fromRGB(60, 60, 150)
                or  Color3.fromRGB(30, 30, 50)
        end
    end)
end

-- ==========================================
-- HELPER: Tạo nút ON/OFF
-- ==========================================
local function MakeToggleBtn(parent, label, feature, onEnable, onDisable, layoutOrder)
    local row = Instance.new("Frame")
    row.Name             = "Row_" .. feature
    row.Size             = UDim2.new(1, -6, 0, 34)
    row.BackgroundColor3 = Color3.fromRGB(28, 28, 40)
    row.BorderSizePixel  = 0
    row.LayoutOrder      = layoutOrder or 0
    row.Parent           = parent

    local rowCorner = Instance.new("UICorner")
    rowCorner.CornerRadius = UDim.new(0, 6)
    rowCorner.Parent = row

    local lbl = Instance.new("TextLabel")
    lbl.Text             = label
    lbl.Size             = UDim2.new(1, -68, 1, 0)
    lbl.Position         = UDim2.new(0, 8, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.TextColor3       = Color3.fromRGB(200, 200, 230)
    lbl.TextSize         = 13
    lbl.Font             = Enum.Font.Gotham
    lbl.TextXAlignment   = Enum.TextXAlignment.Left
    lbl.Parent           = row

    local toggleBtn = Instance.new("TextButton")
    toggleBtn.Text         = "OFF"
    toggleBtn.Size         = UDim2.new(0, 56, 0, 24)
    toggleBtn.Position     = UDim2.new(1, -62, 0.5, -12)
    toggleBtn.BackgroundColor3 = Color3.fromRGB(160, 40, 40)
    toggleBtn.TextColor3   = Color3.fromRGB(255, 255, 255)
    toggleBtn.Font         = Enum.Font.GothamBold
    toggleBtn.TextSize     = 12
    toggleBtn.BorderSizePixel = 0
    toggleBtn.Parent       = row

    local btnCorner = Instance.new("UICorner")
    btnCorner.CornerRadius = UDim.new(0, 5)
    btnCorner.Parent = toggleBtn

    toggleBtn.MouseButton1Click:Connect(function()
        local isOn = StateManager:Toggle(feature)
        if isOn then
            toggleBtn.Text             = "ON"
            toggleBtn.BackgroundColor3 = Color3.fromRGB(40, 150, 40)
            if onEnable then
                local ok, err = pcall(onEnable)
                if not ok then warn("[DebugGUI] Enable error:", err) end
            end
        else
            toggleBtn.Text             = "OFF"
            toggleBtn.BackgroundColor3 = Color3.fromRGB(160, 40, 40)
            if onDisable then
                local ok, err = pcall(onDisable)
                if not ok then warn("[DebugGUI] Disable error:", err) end
            end
        end
    end)

    return row, toggleBtn
end

-- ==========================================
-- HELPER: Tạo slider/nhập số
-- ==========================================
local function MakeSlider(parent, label, configKey, min, max, layoutOrder)
    local row = Instance.new("Frame")
    row.Name             = "Slider_" .. configKey
    row.Size             = UDim2.new(1, -6, 0, 48)
    row.BackgroundColor3 = Color3.fromRGB(28, 28, 40)
    row.BorderSizePixel  = 0
    row.LayoutOrder      = layoutOrder or 0
    row.Parent           = parent

    local rowCorner = Instance.new("UICorner")
    rowCorner.CornerRadius = UDim.new(0, 6)
    rowCorner.Parent = row

    local lbl = Instance.new("TextLabel")
    lbl.Text             = label .. ": " .. tostring(StateManager:GetConfig(configKey))
    lbl.Size             = UDim2.new(1, 0, 0, 20)
    lbl.Position         = UDim2.new(0, 8, 0, 2)
    lbl.BackgroundTransparency = 1
    lbl.TextColor3       = Color3.fromRGB(180, 180, 220)
    lbl.TextSize         = 12
    lbl.Font             = Enum.Font.Gotham
    lbl.TextXAlignment   = Enum.TextXAlignment.Left
    lbl.Parent           = row

    -- Nút giảm
    local minusBtn = Instance.new("TextButton")
    minusBtn.Text         = "−"
    minusBtn.Size         = UDim2.new(0, 28, 0, 22)
    minusBtn.Position     = UDim2.new(0, 8, 0, 22)
    minusBtn.BackgroundColor3 = Color3.fromRGB(80, 40, 40)
    minusBtn.TextColor3   = Color3.fromRGB(255, 255, 255)
    minusBtn.Font         = Enum.Font.GothamBold
    minusBtn.TextSize     = 16
    minusBtn.BorderSizePixel = 0
    minusBtn.Parent       = row

    local minusCorner = Instance.new("UICorner")
    minusCorner.CornerRadius = UDim.new(0, 4)
    minusCorner.Parent = minusBtn

    -- Nhập giá trị
    local valBox = Instance.new("TextBox")
    valBox.Text           = tostring(StateManager:GetConfig(configKey))
    valBox.Size           = UDim2.new(0, 80, 0, 22)
    valBox.Position       = UDim2.new(0, 44, 0, 22)
    valBox.BackgroundColor3 = Color3.fromRGB(40, 40, 60)
    valBox.TextColor3     = Color3.fromRGB(220, 220, 255)
    valBox.Font           = Enum.Font.GothamMedium
    valBox.TextSize       = 12
    valBox.BorderSizePixel = 0
    valBox.ClearTextOnFocus = false
    valBox.Parent         = row

    local valCorner = Instance.new("UICorner")
    valCorner.CornerRadius = UDim.new(0, 4)
    valCorner.Parent = valBox

    -- Nút tăng
    local plusBtn = Instance.new("TextButton")
    plusBtn.Text          = "+"
    plusBtn.Size          = UDim2.new(0, 28, 0, 22)
    plusBtn.Position      = UDim2.new(0, 132, 0, 22)
    plusBtn.BackgroundColor3 = Color3.fromRGB(40, 80, 40)
    plusBtn.TextColor3    = Color3.fromRGB(255, 255, 255)
    plusBtn.Font          = Enum.Font.GothamBold
    plusBtn.TextSize      = 16
    plusBtn.BorderSizePixel = 0
    plusBtn.Parent        = row

    local plusCorner = Instance.new("UICorner")
    plusCorner.CornerRadius = UDim.new(0, 4)
    plusCorner.Parent = plusBtn

    local function UpdateValue(newVal)
        newVal = math.clamp(tonumber(newVal) or StateManager:GetConfig(configKey), min, max)
        StateManager:SetConfig(configKey, newVal)
        valBox.Text = tostring(newVal)
        lbl.Text    = label .. ": " .. tostring(newVal)
    end

    minusBtn.MouseButton1Click:Connect(function() UpdateValue(StateManager:GetConfig(configKey) - 1) end)
    plusBtn.MouseButton1Click:Connect(function()  UpdateValue(StateManager:GetConfig(configKey) + 1) end)
    valBox.FocusLost:Connect(function()           UpdateValue(valBox.Text)                         end)

    return row
end

-- ==========================================
-- SECTION LABEL
-- ==========================================
local function MakeSection(parent, text, layoutOrder)
    local lbl = Instance.new("TextLabel")
    lbl.Text             = "— " .. text .. " —"
    lbl.Size             = UDim2.new(1, -6, 0, 20)
    lbl.BackgroundTransparency = 1
    lbl.TextColor3       = Color3.fromRGB(120, 120, 220)
    lbl.TextSize         = 11
    lbl.Font             = Enum.Font.GothamBold
    lbl.TextXAlignment   = Enum.TextXAlignment.Center
    lbl.LayoutOrder      = layoutOrder or 0
    lbl.Parent           = parent
    return lbl
end

-- ==========================================
-- TAB MAIN: Thêm các nút tính năng
-- ==========================================
local mainPanel = tabPanels["Main"]
local lo        = 0  -- layoutOrder counter

local function LO() lo = lo + 1; return lo end

MakeSection(mainPanel, "COMBAT FEATURES", LO())

MakeToggleBtn(mainPanel, "Tele Dron", "TeleDron",
    function() CombatEngine:StartTeleDron() end,
    function() CombatEngine:StopTeleDron() end,
    LO())

MakeSlider(mainPanel, "Safe Height", "TeleDronSafeHeight", 2, 50, LO())

MakeToggleBtn(mainPanel, "Hitbox All Mod", "HitboxAllMod",
    function() CombatEngine:StartHitboxAllMod() end,
    function() CombatEngine:StopHitboxAllMod() end,
    LO())

MakeSlider(mainPanel, "Hitbox Size", "HitboxSize", 1, 100, LO())  -- simplified (actual uses Vector3)

MakeToggleBtn(mainPanel, "Tele Kill", "TeleKill",
    function() CombatEngine:StartTeleKill() end,
    function() CombatEngine:StopTeleKill() end,
    LO())

MakeToggleBtn(mainPanel, "Aimbot", "Aimbot",
    function() CombatEngine:StartAimbot() end,
    function() CombatEngine:StopAimbot() end,
    LO())

MakeToggleBtn(mainPanel, "All Mod Im", "AllModIm",
    function() CombatEngine:StartAllModIm() end,
    function() CombatEngine:StopAllModIm() end,
    LO())

MakeSection(mainPanel, "MODEL CONTROL", LO())

MakeToggleBtn(mainPanel, "Model Độn Thổ", "ModelBury",
    function() CombatEngine:StartModelBury() end,
    function() CombatEngine:StopModelBury() end,
    LO())

MakeSlider(mainPanel, "Bury Depth", "ModelBuryDepth", -100, 0, LO())

MakeToggleBtn(mainPanel, "Model Head Down", "ModelHeadDown",
    function() CombatEngine:StartModelHeadDown() end,
    function() CombatEngine:StopModelHeadDown() end,
    LO())

MakeSlider(mainPanel, "Head Depth", "ModelHeadDepth", -50, 0, LO())

MakeToggleBtn(mainPanel, "Player Barrier", "PlayerBarrier",
    function() CombatEngine:StartPlayerBarrier() end,
    function() CombatEngine:StopPlayerBarrier() end,
    LO())

MakeSlider(mainPanel, "Barrier Size", "PlayerBarrierSize", 2, 50, LO())

MakeToggleBtn(mainPanel, "Long Legs", "LongLegs",
    function() CombatEngine:StartLongLegs() end,
    function() CombatEngine:StopLongLegs() end,
    LO())

MakeSlider(mainPanel, "Legs Depth", "LongLegsDepth", -100, 0, LO())

MakeToggleBtn(mainPanel, "Long Head", "LongHead",
    function() CombatEngine:StartLongHead() end,
    function() CombatEngine:StopLongHead() end,
    LO())

MakeSlider(mainPanel, "Head Height", "LongHeadHeight", 1, 50, LO())

MakeSlider(mainPanel, "Scan Range", "ScanRange", 10, 500, LO())

-- ==========================================
-- TAB ESP
-- ==========================================
local espPanel = tabPanels["Esp"]
local elo      = 0
local function ELO() elo = elo + 1; return elo end

MakeSection(espPanel, "ESP FEATURES", ELO())

-- Khởi động ESP loop một lần duy nhất (tự cập nhật theo flag)
EspEngine:StartLoop()

MakeToggleBtn(espPanel, "Esp Line", "EspLine",   function() end, function() end, ELO())
MakeToggleBtn(espPanel, "Esp Box",  "EspBox",    function() end, function() end, ELO())
MakeToggleBtn(espPanel, "Esp Name", "EspName",   function() end, function() end, ELO())
MakeToggleBtn(espPanel, "Esp Distance", "EspDistance", function() end, function() end, ELO())
MakeToggleBtn(espPanel, "Esp Hologram", "EspHologram", function() end, function() end, ELO())

MakeSection(espPanel, "RANGE", ELO())
MakeSlider(espPanel, "Scan Range", "ScanRange", 10, 500, ELO())

-- ==========================================
-- TAB KHÁC (Movement & World)
-- ==========================================
local otherPanel = tabPanels["Khác"]
local klo        = 0
local function KLO() klo = klo + 1; return klo end

MakeSection(otherPanel, "BAY & DI CHUYỂN", KLO())

MakeToggleBtn(otherPanel, "Fly Down", "FlyDown",
    function() MovementAndWorld:StartFlyDown() end,
    function() MovementAndWorld:StopFlyDown() end,
    KLO())

MakeSlider(otherPanel, "Fly Down Depth", "FlyDownDepth", -50, 0, KLO())

MakeToggleBtn(otherPanel, "Fly Dron", "FlyDron",
    function() MovementAndWorld:StartFlyDron() end,
    function() MovementAndWorld:StopFlyDron() end,
    KLO())

MakeSlider(otherPanel, "Fly Dron Height", "FlyDronHeight", 0, 50, KLO())

MakeToggleBtn(otherPanel, "No Clip", "NoClip",
    function() MovementAndWorld:StartNoClip() end,
    function() MovementAndWorld:StopNoClip() end,
    KLO())

MakeToggleBtn(otherPanel, "Fly Air", "FlyAir",
    function() MovementAndWorld:StartFlyAir() end,
    function() MovementAndWorld:StopFlyAir() end,
    KLO())

MakeSlider(otherPanel, "Fly Speed", "FlyAirSpeed", 1, 500, KLO())

MakeToggleBtn(otherPanel, "Speed", "Speed",
    function() MovementAndWorld:StartSpeed() end,
    function() MovementAndWorld:StopSpeed() end,
    KLO())

MakeSlider(otherPanel, "Walk Speed", "WalkSpeed", 1, 200, KLO())

MakeToggleBtn(otherPanel, "Jumping Air", "JumpingAir",
    function() MovementAndWorld:StartJumpingAir() end,
    function() MovementAndWorld:StopJumpingAir() end,
    KLO())

MakeSection(otherPanel, "MÔI TRƯỜNG", KLO())

MakeToggleBtn(otherPanel, "Night Vision", "NightVision",
    function() MovementAndWorld:StartNightVision() end,
    function() MovementAndWorld:StopNightVision() end,
    KLO())

MakeToggleBtn(otherPanel, "Fix Lag", "FixLag",
    function() MovementAndWorld:StartFixLag() end,
    function() MovementAndWorld:StopFixLag() end,
    KLO())

-- ==========================================
-- THÔNG BÁO KHỞI ĐỘNG
-- ==========================================
local function ShowNotif(msg, color)
    local notif = Instance.new("Frame")
    notif.Size             = UDim2.new(0, 280, 0, 36)
    notif.Position         = UDim2.new(0.5, -140, 1, -50)
    notif.BackgroundColor3 = color or Color3.fromRGB(40, 40, 80)
    notif.BorderSizePixel  = 0
    notif.Parent           = ScreenGui

    local nc = Instance.new("UICorner")
    nc.CornerRadius = UDim.new(0, 8)
    nc.Parent = notif

    local nl = Instance.new("TextLabel")
    nl.Text              = msg
    nl.Size              = UDim2.new(1, 0, 1, 0)
    nl.BackgroundTransparency = 1
    nl.TextColor3        = Color3.fromRGB(255, 255, 255)
    nl.Font              = Enum.Font.GothamMedium
    nl.TextSize          = 13
    nl.Parent            = notif

    task.delay(2.5, function()
        TweenService:Create(notif, TweenInfo.new(0.4), {BackgroundTransparency = 1}):Play()
        TweenService:Create(nl,    TweenInfo.new(0.4), {TextTransparency = 1}):Play()
        task.wait(0.5)
        notif:Destroy()
    end)
end

ShowNotif("✅ DebugGUI loaded! Phạm vi: 150 studs", Color3.fromRGB(40, 120, 40))

-- ==========================================
-- DỌN DẸP KHI NHÂN VẬT RESPAWN
-- ==========================================
LocalPlayer.CharacterAdded:Connect(function(char)
    char:WaitForChild("HumanoidRootPart", 10)
    -- Reset các tính năng phụ thuộc vào nhân vật
    if StateManager:IsOn("NoClip") then
        task.wait(0.5)
        MovementAndWorld:StartNoClip()
    end
    if StateManager:IsOn("Speed") then
        task.wait(0.5)
        MovementAndWorld:StartSpeed()
    end
    if StateManager:IsOn("FlyAir") then
        task.wait(0.5)
        MovementAndWorld:StartFlyAir()
    end
    ShowNotif("🔄 Character respawned - đã áp dụng lại tính năng")
end)

-- ==========================================
-- PHÍM TẮT: INSERT để ẩn/hiện GUI
-- ==========================================
UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == Enum.KeyCode.Insert then
        MainFrame.Visible = not MainFrame.Visible
    end
end)

print("[DebugGUI] Khởi động thành công! Nhấn INSERT để ẩn/hiện.")
print("[DebugGUI] AttackHook: Chỉnh hàm CombatEngine.AttackHook() để kết nối cơ chế tấn công của game.")
