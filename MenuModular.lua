--[[
    DebugGUI.lua - Giao diện debug/test hoàn chỉnh cho Roblox
    Tác giả: Senior Roblox/Luau Engineer
    Kiến trúc: StateManager | TargetScanner | CombatEngine | EspEngine | MovementAndWorld | UIController
    
    CÁCH CẮM CƠ CHẾ TẤN CÔNG CỦA GAME VÀO CombatEngine:
    - Tìm hàm `AttackHook(target, mode)` ở cuối phần CombatEngine
    - Thay thế `-- TODO: gọi hàm tấn công của game tại đây` bằng API tấn công thực tế
    - Ví dụ: game.ReplicatedStorage.RemoteEvents.Attack:FireServer(target, mode)
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

-- Đợi character load
local function waitForCharacter()
    if not LocalPlayer.Character then
        LocalPlayer.CharacterAdded:Wait()
    end
    local char = LocalPlayer.Character
    char:WaitForChild("HumanoidRootPart", 10)
    char:WaitForChild("Humanoid", 10)
    return char
end

-- ============================================================
-- MODULE: StateManager
-- Quản lý trạng thái, cấu hình, snapshot khôi phục
-- ============================================================
local StateManager = {}
StateManager.__index = StateManager

function StateManager.new()
    local self = setmetatable({}, StateManager)
    -- Trạng thái bật/tắt từng tính năng
    self.States = {
        TeleDron = false,
        HitboxAllMod = false,
        TeleKill = false,
        Aimbot = false,
        AllModIm = false,
        ModelDonTho = false,
        ModelHeadDown = false,
        PlayerBarrier = false,
        LongLegs = false,
        LongHead = false,
        EspLine = false,
        EspBox = false,
        EspName = false,
        EspDistance = false,
        EspHologram = false,
        FlyDown = false,
        FlyDron = false,
        NoClip = false,
        FlyAir = false,
        Speed = false,
        JumpingAir = false,
        NightVision = false,
        FixLag = false,
    }
    -- Tham số cấu hình
    self.Config = {
        ScanRange = 150,
        DroneHeightOffset = 10,   -- Độ cao lơ lửng trên mob (Tele Dron)
        FlySpeed = 6,              -- Tốc độ bay mặc định
        WalkSpeed = 16,            -- Tốc độ đi bộ mặc định
        HitboxSize = 10,           -- Kích thước hitbox tăng
        BarrierSize = 8,           -- Kích thước rào chắn
        DonThoDepth = -15,         -- Độ sâu độn thổ (studs)
        HeadDownDepth = -5,        -- Độ sâu cắm đầu
        LongLegsDepth = -20,       -- Độ dài chân xuống đất
        LongHeadHeight = 10,       -- Độ cao đầu dài
        FlyDronHeight = 6,         -- Độ cao FlyDron mặc định
    }
    -- Snapshot lưu giá trị gốc
    self.Snapshots = {}
    return self
end

function StateManager:SaveSnapshot(key, value)
    self.Snapshots[key] = value
end

function StateManager:GetSnapshot(key)
    return self.Snapshots[key]
end

function StateManager:ClearSnapshot(key)
    self.Snapshots[key] = nil
end

function StateManager:Toggle(feature)
    self.States[feature] = not self.States[feature]
    return self.States[feature]
end

function StateManager:IsOn(feature)
    return self.States[feature] == true
end

local State = StateManager.new()

-- ============================================================
-- MODULE: TargetScanner
-- Quét mục tiêu hợp lệ trong 150 studs, cache theo frame
-- ============================================================
local TargetScanner = {}
TargetScanner.__index = TargetScanner

function TargetScanner.new()
    local self = setmetatable({}, TargetScanner)
    self._cache = {}           -- Cache danh sách mục tiêu
    self._lastScanFrame = 0    -- Frame cuối cùng quét
    self._scanInterval = 10    -- Quét lại mỗi 10 frame để tiết kiệm CPU
    return self
end

-- Kiểm tra model có hợp lệ không (NPC/Mob, không phải player)
function TargetScanner:IsValidTarget(model)
    if not model or not model:IsA("Model") then return false end
    -- Loại bỏ chính mình
    if model == LocalPlayer.Character then return false end
    -- Loại bỏ nhân vật của player khác
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Character == model then return false end
    end
    -- Phải có Humanoid còn sống
    local hum = model:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then return false end
    -- Phải có HumanoidRootPart hoặc PrimaryPart
    local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
    if not root then return false end
    return true
end

-- Lấy danh sách mục tiêu (có cache theo frame)
function TargetScanner:GetTargets()
    local currentFrame = RunService.Heartbeat:Wait() and tick()
    -- Dùng frame counter thực tế
    local char = LocalPlayer.Character
    if not char then return {} end
    local root = char:FindFirstChild("HumanoidRootPart")
    if not root then return {} end

    -- Kiểm tra xem có cần quét lại không (dùng tick để debounce)
    if tick() - (self._lastScanTick or 0) < 0.1 then
        return self._cache
    end
    self._lastScanTick = tick()

    local targets = {}
    local myPos = root.Position
    local range = State.Config.ScanRange

    -- Quét toàn bộ Workspace
    for _, obj in ipairs(Workspace:GetDescendants()) do
        if obj:IsA("Model") and self:IsValidTarget(obj) then
            local objRoot = obj:FindFirstChild("HumanoidRootPart") or obj.PrimaryPart
            if objRoot then
                local dist = (objRoot.Position - myPos).Magnitude
                if dist <= range then
                    table.insert(targets, {model = obj, distance = dist, root = objRoot})
                end
            end
        end
    end

    -- Sắp xếp theo khoảng cách gần nhất
    table.sort(targets, function(a, b) return a.distance < b.distance end)
    self._cache = targets
    return targets
end

-- Lấy mục tiêu gần nhất
function TargetScanner:GetNearest()
    local targets = self:GetTargets()
    return targets[1]
end

local Scanner = TargetScanner.new()

-- ============================================================
-- MODULE: CombatEngine
-- Tele Dron, Hitbox, Tele Kill, Aimbot, All Mod Im, v.v.
-- ============================================================
local CombatEngine = {}
CombatEngine._connections = {}  -- Lưu các kết nối sự kiện
CombatEngine._currentTarget = nil
CombatEngine._barrierParts = {}

-- Hàm hook tấn công - THAY THẾ NỘI DUNG NÀY theo game cụ thể
-- mode: "melee" | "ranged" | "skill"
function CombatEngine.AttackHook(target, mode)
    if not target or not target.root then return end
    --[[
        TODO: Thay thế bằng remote/function tấn công thực tế của game, ví dụ:
        
        -- Ví dụ 1: FireServer remote attack
        local Remote = game.ReplicatedStorage:FindFirstChild("AttackRemote")
        if Remote then Remote:FireServer(target.model, mode) end
        
        -- Ví dụ 2: Dùng Tool/đòn đánh của nhân vật
        local char = LocalPlayer.Character
        local tool = char:FindFirstChildOfClass("Tool")
        if tool and tool:FindFirstChild("Handle") then
            -- kích hoạt tấn công
        end
    ]]
    -- Debug: in ra console để kiểm tra
    -- print("[CombatEngine] Attack:", target.model.Name, "mode:", mode)
end

-- Dọn kết nối an toàn
local function disconnectAll(tbl)
    for k, conn in pairs(tbl) do
        if conn and typeof(conn) == "RBXScriptConnection" then
            pcall(function() conn:Disconnect() end)
        end
        tbl[k] = nil
    end
end

-- ---- Tele Dron ----
function CombatEngine.StartTeleDron()
    local conn = RunService.Heartbeat:Connect(function()
        if not State:IsOn("TeleDron") then return end
        local char = LocalPlayer.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if not root then return end

        local nearest = Scanner:GetNearest()
        if not nearest then return end

        -- Tính vị trí lơ lửng trên mob
        local safeHeight = State.Config.DroneHeightOffset
        local targetPos = nearest.root.Position + Vector3.new(0, safeHeight, 0)

        -- Dịch chuyển nhân vật tới vị trí drone
        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum then
            -- Triệt tiêu rơi: đặt Velocity = 0
            pcall(function()
                local hrp = root
                local vel = hrp:FindFirstChildOfClass("LinearVelocity")
                    or Instance.new("LinearVelocity", hrp)
                vel.Name = "DroneLock"
                vel.MaxForce = Vector3.new(1e5, 1e5, 1e5)
                vel.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
                vel.RelativeTo = Enum.ActuatorRelativeTo.World
                vel.ForceLimitsEnabled = false
            end)
            -- Dịch chuyển nhân vật
            root.CFrame = CFrame.new(targetPos)
        end

        -- Kích hoạt tấn công hướng xuống
        CombatEngine.AttackHook(nearest, "melee")

        -- Chuyển mục tiêu nếu mob chết
        local hTarget = nearest.model:FindFirstChildOfClass("Humanoid")
        if hTarget and hTarget.Health <= 0 then
            Scanner._lastScanTick = 0 -- Force rescan
        end
    end)
    CombatEngine._connections["TeleDron"] = conn
end

function CombatEngine.StopTeleDron()
    if CombatEngine._connections["TeleDron"] then
        pcall(function() CombatEngine._connections["TeleDron"]:Disconnect() end)
        CombatEngine._connections["TeleDron"] = nil
    end
    -- Dọn LinearVelocity nếu còn
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if root then
        local vel = root:FindFirstChild("DroneLock")
        if vel then vel:Destroy() end
    end
end

-- ---- Hitbox All Mod ----
local _hitboxOriginals = {} -- {part => {Size=, CFrame=}}

function CombatEngine.StartHitboxAllMod()
    local targets = Scanner:GetTargets()
    for _, t in ipairs(targets) do
        for _, part in ipairs(t.model:GetDescendants()) do
            if part:IsA("BasePart") then
                _hitboxOriginals[part] = {Size = part.Size, CFrame = part.CFrame}
                pcall(function()
                    local size = State.Config.HitboxSize
                    part.Size = Vector3.new(size, size, size)
                    part.CanCollide = false -- Xuyên vật cản
                    part.CFrame = part.CFrame -- giữ nguyên vị trí
                end)
            end
        end
    end
    -- Cập nhật liên tục theo frame khi có mob mới
    local conn = RunService.Heartbeat:Connect(function()
        if not State:IsOn("HitboxAllMod") then return end
        local newTargets = Scanner:GetTargets()
        for _, t in ipairs(newTargets) do
            for _, part in ipairs(t.model:GetDescendants()) do
                if part:IsA("BasePart") and not _hitboxOriginals[part] then
                    _hitboxOriginals[part] = {Size = part.Size}
                    pcall(function()
                        local size = State.Config.HitboxSize
                        part.Size = Vector3.new(size, size, size)
                        part.CanCollide = false
                    end)
                end
            end
        end
    end)
    CombatEngine._connections["HitboxAllMod"] = conn
end

function CombatEngine.StopHitboxAllMod()
    if CombatEngine._connections["HitboxAllMod"] then
        pcall(function() CombatEngine._connections["HitboxAllMod"]:Disconnect() end)
        CombatEngine._connections["HitboxAllMod"] = nil
    end
    -- Khôi phục kích thước gốc
    for part, orig in pairs(_hitboxOriginals) do
        pcall(function()
            if part and part.Parent then
                part.Size = orig.Size
                part.CanCollide = true
            end
        end)
    end
    _hitboxOriginals = {}
end

-- ---- Tele Kill ----
function CombatEngine.StartTeleKill()
    local running = true
    task.spawn(function()
        while running and State:IsOn("TeleKill") do
            local nearest = Scanner:GetNearest()
            if nearest then
                local char = LocalPlayer.Character
                local root = char and char:FindFirstChild("HumanoidRootPart")
                if root then
                    -- Dịch chuyển tới sát bên mục tiêu
                    local offset = Vector3.new(2, 0, 2)
                    root.CFrame = CFrame.new(nearest.root.Position + offset)
                    task.wait(0.05)
                    CombatEngine.AttackHook(nearest, "melee")
                    -- Chờ mob chết hoặc tiếp tục
                    task.wait(0.3)
                end
            else
                task.wait(0.5)
            end
        end
    end)
    -- Lưu cờ để dừng
    CombatEngine._connections["TeleKill"] = {
        Disconnect = function() running = false end
    }
end

function CombatEngine.StopTeleKill()
    if CombatEngine._connections["TeleKill"] then
        pcall(function() CombatEngine._connections["TeleKill"]:Disconnect() end)
        CombatEngine._connections["TeleKill"] = nil
    end
end

-- ---- Aimbot ----
function CombatEngine.StartAimbot()
    local conn = RunService.RenderStepped:Connect(function()
        if not State:IsOn("Aimbot") then return end
        local nearest = Scanner:GetNearest()
        if not nearest then return end
        local cam = Workspace.CurrentCamera
        -- Tính hướng từ camera tới mục tiêu
        local targetPos = nearest.root.Position
        local camPos = cam.CFrame.Position
        -- Ghim camera mượt mà bằng Tween nhỏ
        local lookCF = CFrame.new(camPos, targetPos)
        cam.CFrame = cam.CFrame:Lerp(lookCF, 0.2)
    end)
    CombatEngine._connections["Aimbot"] = conn
end

function CombatEngine.StopAimbot()
    if CombatEngine._connections["Aimbot"] then
        pcall(function() CombatEngine._connections["Aimbot"]:Disconnect() end)
        CombatEngine._connections["Aimbot"] = nil
    end
end

-- ---- All Mod Im (Freeze + vô hiệu tấn công) ----
local _modImOriginals = {} -- {humanoid => {WalkSpeed=, JumpPower=, ...}}

function CombatEngine.StartAllModIm()
    local targets = Scanner:GetTargets()
    for _, t in ipairs(targets) do
        local hum = t.model:FindFirstChildOfClass("Humanoid")
        if hum and not _modImOriginals[hum] then
            _modImOriginals[hum] = {
                WalkSpeed = hum.WalkSpeed,
                JumpPower = hum.JumpPower,
            }
            pcall(function()
                hum.WalkSpeed = 0
                hum.JumpPower = 0
            end)
        end
        -- Vô hiệu tấn công tầm xa: dịch xuống đất
        for _, part in ipairs(t.model:GetDescendants()) do
            if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
                pcall(function() part.CanCollide = false end)
            end
        end
    end
    local conn = RunService.Heartbeat:Connect(function()
        if not State:IsOn("AllModIm") then return end
        local newTargets = Scanner:GetTargets()
        for _, t in ipairs(newTargets) do
            local hum = t.model:FindFirstChildOfClass("Humanoid")
            if hum and not _modImOriginals[hum] then
                _modImOriginals[hum] = {WalkSpeed = hum.WalkSpeed, JumpPower = hum.JumpPower}
                pcall(function() hum.WalkSpeed = 0; hum.JumpPower = 0 end)
            end
        end
    end)
    CombatEngine._connections["AllModIm"] = conn
end

function CombatEngine.StopAllModIm()
    if CombatEngine._connections["AllModIm"] then
        pcall(function() CombatEngine._connections["AllModIm"]:Disconnect() end)
        CombatEngine._connections["AllModIm"] = nil
    end
    for hum, orig in pairs(_modImOriginals) do
        pcall(function()
            if hum and hum.Parent then
                hum.WalkSpeed = orig.WalkSpeed
                hum.JumpPower = orig.JumpPower
            end
        end)
    end
    _modImOriginals = {}
end

-- ---- Model Độn Thổ ----
local _donThoOriginals = {}

function CombatEngine.StartModelDonTho()
    local depth = State.Config.DonThoDepth
    local targets = Scanner:GetTargets()
    for _, t in ipairs(targets) do
        local root = t.root
        if root and not _donThoOriginals[root] then
            _donThoOriginals[root] = root.CFrame
            pcall(function()
                -- Dịch toàn model xuống dưới lòng đất
                local offset = Vector3.new(0, depth, 0)
                local pivotCF = t.model:GetPivot()
                t.model:PivotTo(pivotCF + offset)
                -- Vô hiệu va chạm
                for _, p in ipairs(t.model:GetDescendants()) do
                    if p:IsA("BasePart") then p.CanCollide = false end
                end
            end)
        end
    end
    local conn = RunService.Heartbeat:Connect(function()
        if not State:IsOn("ModelDonTho") then return end
        local newT = Scanner:GetTargets()
        for _, t in ipairs(newT) do
            local root = t.root
            if root and not _donThoOriginals[root] then
                _donThoOriginals[root] = root.CFrame
                local offset = Vector3.new(0, State.Config.DonThoDepth, 0)
                pcall(function()
                    local pivotCF = t.model:GetPivot()
                    t.model:PivotTo(pivotCF + offset)
                    for _, p in ipairs(t.model:GetDescendants()) do
                        if p:IsA("BasePart") then p.CanCollide = false end
                    end
                end)
            end
        end
    end)
    CombatEngine._connections["ModelDonTho"] = conn
end

function CombatEngine.StopModelDonTho()
    if CombatEngine._connections["ModelDonTho"] then
        pcall(function() CombatEngine._connections["ModelDonTho"]:Disconnect() end)
        CombatEngine._connections["ModelDonTho"] = nil
    end
    for root, origCF in pairs(_donThoOriginals) do
        pcall(function()
            if root and root.Parent then
                local model = root:FindFirstAncestorOfClass("Model")
                if model then
                    model:PivotTo(origCF)
                    for _, p in ipairs(model:GetDescendants()) do
                        if p:IsA("BasePart") then p.CanCollide = true end
                    end
                end
            end
        end)
    end
    _donThoOriginals = {}
end

-- ---- Model Head Down ----
local _headDownOriginals = {}

function CombatEngine.StartModelHeadDown()
    local targets = Scanner:GetTargets()
    for _, t in ipairs(targets) do
        local head = t.model:FindFirstChild("Head")
        local root = t.root
        if head and root and not _headDownOriginals[root] then
            _headDownOriginals[root] = {
                headCF = head.CFrame,
                rootCF = root.CFrame,
            }
            pcall(function()
                -- Cắm đầu xuống đất, giữ thân lên trên
                local depth = State.Config.HeadDownDepth
                -- Lật ngược model (đầu xuống)
                local pivotCF = t.model:GetPivot()
                t.model:PivotTo(CFrame.new(pivotCF.Position)
                    * CFrame.Angles(math.pi, 0, 0)
                    + Vector3.new(0, depth, 0))
                for _, p in ipairs(t.model:GetDescendants()) do
                    if p:IsA("BasePart") then p.CanCollide = false end
                end
            end)
        end
    end
    local conn = RunService.Heartbeat:Connect(function()
        if not State:IsOn("ModelHeadDown") then return end
        local newT = Scanner:GetTargets()
        for _, t in ipairs(newT) do
            local root = t.root
            if root and not _headDownOriginals[root] then
                _headDownOriginals[root] = {rootCF = root.CFrame}
                local depth = State.Config.HeadDownDepth
                pcall(function()
                    local pivotCF = t.model:GetPivot()
                    t.model:PivotTo(CFrame.new(pivotCF.Position)
                        * CFrame.Angles(math.pi, 0, 0)
                        + Vector3.new(0, depth, 0))
                    for _, p in ipairs(t.model:GetDescendants()) do
                        if p:IsA("BasePart") then p.CanCollide = false end
                    end
                end)
            end
        end
    end)
    CombatEngine._connections["ModelHeadDown"] = conn
end

function CombatEngine.StopModelHeadDown()
    if CombatEngine._connections["ModelHeadDown"] then
        pcall(function() CombatEngine._connections["ModelHeadDown"]:Disconnect() end)
        CombatEngine._connections["ModelHeadDown"] = nil
    end
    for root, orig in pairs(_headDownOriginals) do
        pcall(function()
            if root and root.Parent then
                local model = root:FindFirstAncestorOfClass("Model")
                if model then
                    model:PivotTo(orig.rootCF)
                    for _, p in ipairs(model:GetDescendants()) do
                        if p:IsA("BasePart") then p.CanCollide = true end
                    end
                end
            end
        end)
    end
    _headDownOriginals = {}
end

-- ---- Player Barrier ----
function CombatEngine.StartPlayerBarrier()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return end

    -- Tạo Part rào chắn vô hình
    local barrier = Instance.new("Part")
    barrier.Name = "PlayerBarrier"
    barrier.Size = Vector3.new(
        State.Config.BarrierSize,
        State.Config.BarrierSize,
        State.Config.BarrierSize
    )
    barrier.Anchored = false
    barrier.CanCollide = true
    barrier.Transparency = 1  -- Vô hình
    barrier.CastShadow = false
    barrier.Material = Enum.Material.SmoothPlastic
    barrier.Parent = char

    -- Weld rào chắn vào nhân vật
    local weld = Instance.new("WeldConstraint")
    weld.Part0 = root
    weld.Part1 = barrier
    weld.Parent = barrier

    -- Thêm CollisionGroup xử lý chặn mob
    -- (nếu game có CollisionGroup setup sẵn thì set ở đây)
    table.insert(CombatEngine._barrierParts, barrier)

    -- Cập nhật kích thước theo config
    local conn = RunService.Heartbeat:Connect(function()
        if not State:IsOn("PlayerBarrier") then return end
        if barrier and barrier.Parent then
            local s = State.Config.BarrierSize
            barrier.Size = Vector3.new(s, s, s)
        end
    end)
    CombatEngine._connections["PlayerBarrier"] = conn
end

function CombatEngine.StopPlayerBarrier()
    if CombatEngine._connections["PlayerBarrier"] then
        pcall(function() CombatEngine._connections["PlayerBarrier"]:Disconnect() end)
        CombatEngine._connections["PlayerBarrier"] = nil
    end
    for _, part in ipairs(CombatEngine._barrierParts) do
        pcall(function() if part and part.Parent then part:Destroy() end end)
    end
    CombatEngine._barrierParts = {}
end

-- ---- Long Legs ----
local _longLegsOriginals = {}

function CombatEngine.StartLongLegs()
    local targets = Scanner:GetTargets()
    local function applyLongLegs(t)
        for _, part in ipairs(t.model:GetDescendants()) do
            if part:IsA("BasePart") and
                (part.Name:lower():find("leg") or part.Name:lower():find("foot")) then
                if not _longLegsOriginals[part] then
                    _longLegsOriginals[part] = {Size = part.Size, CFrame = part.CFrame}
                    pcall(function()
                        local depth = math.abs(State.Config.LongLegsDepth)
                        part.Size = Vector3.new(part.Size.X, depth, part.Size.Z)
                        -- Dịch xuống để chân thò xuống đất
                        part.CFrame = part.CFrame + Vector3.new(0, -depth/2, 0)
                    end)
                end
            end
        end
    end
    for _, t in ipairs(targets) do applyLongLegs(t) end
    local conn = RunService.Heartbeat:Connect(function()
        if not State:IsOn("LongLegs") then return end
        for _, t in ipairs(Scanner:GetTargets()) do applyLongLegs(t) end
    end)
    CombatEngine._connections["LongLegs"] = conn
end

function CombatEngine.StopLongLegs()
    if CombatEngine._connections["LongLegs"] then
        pcall(function() CombatEngine._connections["LongLegs"]:Disconnect() end)
        CombatEngine._connections["LongLegs"] = nil
    end
    for part, orig in pairs(_longLegsOriginals) do
        pcall(function()
            if part and part.Parent then
                part.Size = orig.Size
                part.CFrame = orig.CFrame
            end
        end)
    end
    _longLegsOriginals = {}
end

-- ---- Long Head ----
local _longHeadOriginals = {}

function CombatEngine.StartLongHead()
    local targets = Scanner:GetTargets()
    local function applyLongHead(t)
        local head = t.model:FindFirstChild("Head")
        if head and not _longHeadOriginals[head] then
            _longHeadOriginals[head] = {Size = head.Size, CFrame = head.CFrame}
            pcall(function()
                local h = State.Config.LongHeadHeight
                head.Size = Vector3.new(head.Size.X * 2, h, head.Size.Z * 2)
                head.CFrame = head.CFrame + Vector3.new(0, h/2, 0)
            end)
        end
    end
    for _, t in ipairs(targets) do applyLongHead(t) end
    local conn = RunService.Heartbeat:Connect(function()
        if not State:IsOn("LongHead") then return end
        for _, t in ipairs(Scanner:GetTargets()) do applyLongHead(t) end
    end)
    CombatEngine._connections["LongHead"] = conn
end

function CombatEngine.StopLongHead()
    if CombatEngine._connections["LongHead"] then
        pcall(function() CombatEngine._connections["LongHead"]:Disconnect() end)
        CombatEngine._connections["LongHead"] = nil
    end
    for head, orig in pairs(_longHeadOriginals) do
        pcall(function()
            if head and head.Parent then
                head.Size = orig.Size
                head.CFrame = orig.CFrame
            end
        end)
    end
    _longHeadOriginals = {}
end

-- ============================================================
-- MODULE: EspEngine
-- Esp Line, Box, Name, Distance, Hologram
-- ============================================================
local EspEngine = {}
EspEngine._drawings = {}     -- {targetRoot => {line=, box=, name=, dist=}}
EspEngine._highlights = {}   -- {model => Highlight}
EspEngine._connections = {}

-- Tạo Drawing object an toàn
local function newDrawing(type)
    local ok, obj = pcall(Drawing.new, type)
    if ok then return obj end
    return nil
end

-- Lấy vị trí 2D từ 3D (World to Screen)
local function worldToScreen(pos)
    local cam = Workspace.CurrentCamera
    local screenPos, onScreen = cam:WorldToViewportPoint(pos)
    return Vector2.new(screenPos.X, screenPos.Y), onScreen, screenPos.Z
end

-- Lấy bounding box 2D của model
local function getModelBounds2D(model)
    local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
    local onScreenAny = false
    for _, part in ipairs(model:GetDescendants()) do
        if part:IsA("BasePart") then
            local corners = {
                part.CFrame * CFrame.new( part.Size.X/2,  part.Size.Y/2,  part.Size.Z/2),
                part.CFrame * CFrame.new(-part.Size.X/2,  part.Size.Y/2,  part.Size.Z/2),
                part.CFrame * CFrame.new( part.Size.X/2, -part.Size.Y/2,  part.Size.Z/2),
                part.CFrame * CFrame.new(-part.Size.X/2, -part.Size.Y/2,  part.Size.Z/2),
                part.CFrame * CFrame.new( part.Size.X/2,  part.Size.Y/2, -part.Size.Z/2),
                part.CFrame * CFrame.new(-part.Size.X/2,  part.Size.Y/2, -part.Size.Z/2),
                part.CFrame * CFrame.new( part.Size.X/2, -part.Size.Y/2, -part.Size.Z/2),
                part.CFrame * CFrame.new(-part.Size.X/2, -part.Size.Y/2, -part.Size.Z/2),
            }
            for _, cf in ipairs(corners) do
                local sp, onScreen = worldToScreen(cf.Position)
                if onScreen then
                    onScreenAny = true
                    if sp.X < minX then minX = sp.X end
                    if sp.X > maxX then maxX = sp.X end
                    if sp.Y < minY then minY = sp.Y end
                    if sp.Y > maxY then maxY = sp.Y end
                end
            end
        end
    end
    if not onScreenAny then return nil end
    return minX, minY, maxX, maxY
end

-- Dọn dẹp drawings cho một mục tiêu
local function cleanupTarget(key)
    local d = EspEngine._drawings[key]
    if d then
        for _, obj in pairs(d) do
            if obj and typeof(obj) == "Drawing" then
                pcall(function() obj:Remove() end)
            end
        end
        EspEngine._drawings[key] = nil
    end
end

-- Dọn dẹp highlight cho một model
local function cleanupHighlight(model)
    local hl = EspEngine._highlights[model]
    if hl then
        pcall(function() hl:Destroy() end)
        EspEngine._highlights[model] = nil
    end
end

-- Dọn tất cả ESP
function EspEngine.CleanupAll()
    for key, _ in pairs(EspEngine._drawings) do
        cleanupTarget(key)
    end
    for model, _ in pairs(EspEngine._highlights) do
        cleanupHighlight(model)
    end
end

-- Vòng lặp render ESP chính
function EspEngine.StartRenderLoop()
    if EspEngine._connections["Render"] then return end

    local conn = RunService.RenderStepped:Connect(function()
        local anyEsp = State:IsOn("EspLine") or State:IsOn("EspBox")
            or State:IsOn("EspName") or State:IsOn("EspDistance")
            or State:IsOn("EspHologram")
        if not anyEsp then return end

        local cam = Workspace.CurrentCamera
        local vp = cam.ViewportSize
        local targets = Scanner:GetTargets()

        -- Thu thập keys hiện tại
        local activeKeys = {}

        for _, t in ipairs(targets) do
            local key = tostring(t.root)
            activeKeys[key] = true

            if not EspEngine._drawings[key] then
                EspEngine._drawings[key] = {}
            end
            local d = EspEngine._drawings[key]

            local rootPos = t.root.Position
            local screenPos, onScreen, depth = worldToScreen(rootPos)
            if not onScreen or depth < 0 then
                -- Mục tiêu sau lưng camera, ẩn
                for _, obj in pairs(d) do
                    pcall(function() if obj then obj.Visible = false end end)
                end
                goto continue
            end

            -- ---- ESP LINE ----
            if State:IsOn("EspLine") then
                if not d.line then
                    d.line = newDrawing("Line")
                    if d.line then
                        d.line.Color = Color3.fromRGB(255, 50, 50)
                        d.line.Thickness = 1.5
                        d.line.Transparency = 1
                        d.line.ZIndex = 1
                    end
                end
                if d.line then
                    d.line.From = Vector2.new(vp.X / 2, 0) -- Cạnh trên giữa màn hình
                    d.line.To = screenPos
                    d.line.Visible = true
                end
            elseif d.line then
                d.line.Visible = false
            end

            -- ---- ESP BOX ----
            if State:IsOn("EspBox") then
                local bx1, by1, bx2, by2 = getModelBounds2D(t.model)
                if bx1 then
                    -- Vẽ 4 đường thẳng thành hình chữ nhật
                    local function ensureBoxLine(name, color)
                        if not d["box_"..name] then
                            d["box_"..name] = newDrawing("Line")
                            if d["box_"..name] then
                                d["box_"..name].Color = color or Color3.fromRGB(0, 255, 0)
                                d["box_"..name].Thickness = 1.5
                                d["box_"..name].Transparency = 1
                            end
                        end
                        return d["box_"..name]
                    end
                    local top    = ensureBoxLine("top")
                    local bottom = ensureBoxLine("bottom")
                    local left   = ensureBoxLine("left")
                    local right  = ensureBoxLine("right")
                    if top then
                        top.From = Vector2.new(bx1, by1); top.To = Vector2.new(bx2, by1); top.Visible = true
                    end
                    if bottom then
                        bottom.From = Vector2.new(bx1, by2); bottom.To = Vector2.new(bx2, by2); bottom.Visible = true
                    end
                    if left then
                        left.From = Vector2.new(bx1, by1); left.To = Vector2.new(bx1, by2); left.Visible = true
                    end
                    if right then
                        right.From = Vector2.new(bx2, by1); right.To = Vector2.new(bx2, by2); right.Visible = true
                    end
                end
            else
                for _, side in ipairs({"top","bottom","left","right"}) do
                    if d["box_"..side] then d["box_"..side].Visible = false end
                end
            end

            -- ---- ESP NAME ----
            if State:IsOn("EspName") then
                if not d.name then
                    d.name = newDrawing("Text")
                    if d.name then
                        d.name.Color = Color3.fromRGB(255, 255, 255)
                        d.name.Size = 14
                        d.name.Center = true
                        d.name.Outline = true
                    end
                end
                if d.name then
                    d.name.Text = t.model.Name
                    d.name.Position = screenPos - Vector2.new(0, 20)
                    d.name.Visible = true
                end
            elseif d.name then
                d.name.Visible = false
            end

            -- ---- ESP DISTANCE ----
            if State:IsOn("EspDistance") then
                if not d.dist then
                    d.dist = newDrawing("Text")
                    if d.dist then
                        d.dist.Color = Color3.fromRGB(255, 220, 0)
                        d.dist.Size = 12
                        d.dist.Center = true
                        d.dist.Outline = true
                    end
                end
                if d.dist then
                    d.dist.Text = string.format("%.1f m", t.distance)
                    d.dist.Position = screenPos + Vector2.new(0, 10)
                    d.dist.Visible = true
                end
            elseif d.dist then
                d.dist.Visible = false
            end

            -- ---- ESP HOLOGRAM (Highlight xuyên tường) ----
            if State:IsOn("EspHologram") then
                if not EspEngine._highlights[t.model] then
                    local hl = Instance.new("Highlight")
                    hl.Adornee = t.model
                    hl.FillColor = Color3.fromRGB(255, 100, 0)
                    hl.FillTransparency = 0.5
                    hl.OutlineColor = Color3.fromRGB(255, 255, 0)
                    hl.OutlineTransparency = 0
                    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop -- Xuyên tường
                    hl.Parent = t.model
                    EspEngine._highlights[t.model] = hl
                end
            else
                if EspEngine._highlights[t.model] then
                    cleanupHighlight(t.model)
                end
            end

            ::continue::
        end

        -- Dọn dẹp mục tiêu đã ra ngoài phạm vi/chết
        for key, _ in pairs(EspEngine._drawings) do
            if not activeKeys[key] then
                cleanupTarget(key)
            end
        end
        -- Dọn highlight model không còn trong targets
        for model, _ in pairs(EspEngine._highlights) do
            local stillActive = false
            for _, t in ipairs(targets) do
                if t.model == model then stillActive = true; break end
            end
            if not stillActive then cleanupHighlight(model) end
        end
    end)
    EspEngine._connections["Render"] = conn
end

function EspEngine.StopRenderLoop()
    if EspEngine._connections["Render"] then
        pcall(function() EspEngine._connections["Render"]:Disconnect() end)
        EspEngine._connections["Render"] = nil
    end
    EspEngine.CleanupAll()
end

-- ============================================================
-- MODULE: MovementAndWorld
-- Fly Down, Fly Dron, No Clip, Fly Air, Speed, Jumping Air, Night Vision, Fix Lag
-- ============================================================
local MovementAndWorld = {}
MovementAndWorld._connections = {}
MovementAndWorld._flyBodyForces = {}

-- Utility: lấy BodyVelocity hoặc tạo mới
local function getOrCreateBodyVelocity(root, name)
    local bv = root:FindFirstChild(name)
    if not bv or not bv:IsA("BodyVelocity") then
        bv = Instance.new("BodyVelocity")
        bv.Name = name
        bv.MaxForce = Vector3.new(1e5, 1e5, 1e5)
        bv.Velocity = Vector3.zero
        bv.Parent = root
    end
    return bv
end

local function getOrCreateBodyGyro(root, name)
    local bg = root:FindFirstChild(name)
    if not bg or not bg:IsA("BodyGyro") then
        bg = Instance.new("BodyGyro")
        bg.Name = name
        bg.MaxTorque = Vector3.new(1e5, 1e5, 1e5)
        bg.D = 100
        bg.Parent = root
    end
    return bg
end

-- ---- Fly Down ----
function MovementAndWorld.StartFlyDown()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return end
    local hum = char:FindFirstChildOfClass("Humanoid")
    State:SaveSnapshot("FlyDown_CamCF", Workspace.CurrentCamera.CFrame)

    -- Lật ngửa nhân vật, đưa xuống đất
    local bv = getOrCreateBodyVelocity(root, "FlyDownBV")
    local bg = getOrCreateBodyGyro(root, "FlyDownBG")
    if hum then hum.PlatformStand = true end

    -- Nằm ngửa (xoay 90 độ)
    bg.CFrame = root.CFrame * CFrame.Angles(-math.pi/2, 0, 0)

    local conn = RunService.Heartbeat:Connect(function()
        if not State:IsOn("FlyDown") then return end
        local char2 = LocalPlayer.Character
        local root2 = char2 and char2:FindFirstChild("HumanoidRootPart")
        if not root2 then return end

        local moveDir = Vector3.zero
        -- Điều khiển lên/xuống bằng phím (Q = xuống, E = lên)
        if UserInputService:IsKeyDown(Enum.KeyCode.Q) then
            moveDir = moveDir + Vector3.new(0, -1, 0)
        end
        if UserInputService:IsKeyDown(Enum.KeyCode.E) then
            moveDir = moveDir + Vector3.new(0, 1, 0)
        end

        local bv2 = root2:FindFirstChild("FlyDownBV")
        if bv2 then bv2.Velocity = moveDir * State.Config.FlySpeed end
    end)
    MovementAndWorld._connections["FlyDown"] = conn
end

function MovementAndWorld.StopFlyDown()
    if MovementAndWorld._connections["FlyDown"] then
        pcall(function() MovementAndWorld._connections["FlyDown"]:Disconnect() end)
        MovementAndWorld._connections["FlyDown"] = nil
    end
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if root then
        local bv = root:FindFirstChild("FlyDownBV")
        if bv then bv:Destroy() end
        local bg = root:FindFirstChild("FlyDownBG")
        if bg then bg:Destroy() end
    end
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum then hum.PlatformStand = false end
    -- Giữ nguyên góc camera gốc
    -- (Camera tự restore khi PlatformStand = false)
end

-- ---- Fly Dron ----
function MovementAndWorld.StartFlyDron()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if hum then hum.PlatformStand = true end

    -- Tư thế úp mặt xuống
    local bg = getOrCreateBodyGyro(root, "FlyDronBG")
    bg.CFrame = root.CFrame * CFrame.Angles(math.pi/2, 0, 0)
    local bv = getOrCreateBodyVelocity(root, "FlyDronBV")

    local targetHeight = root.Position.Y + State.Config.FlyDronHeight

    local conn = RunService.Heartbeat:Connect(function()
        if not State:IsOn("FlyDron") then return end
        local char2 = LocalPlayer.Character
        local root2 = char2 and char2:FindFirstChild("HumanoidRootPart")
        if not root2 then return end
        local bv2 = root2:FindFirstChild("FlyDronBV")
        if not bv2 then return end

        -- Duy trì độ cao cố định, không rơi
        local currentY = root2.Position.Y
        local yCorrect = (targetHeight - currentY) * 10

        -- Di chuyển theo hướng camera
        local cam = Workspace.CurrentCamera
        local camFlat = Vector3.new(cam.CFrame.LookVector.X, 0, cam.CFrame.LookVector.Z).Unit
        local moveDir = Vector3.zero
        if UserInputService:IsKeyDown(Enum.KeyCode.W) then moveDir = moveDir + camFlat end
        if UserInputService:IsKeyDown(Enum.KeyCode.S) then moveDir = moveDir - camFlat end
        if UserInputService:IsKeyDown(Enum.KeyCode.A) then
            moveDir = moveDir - cam.CFrame.RightVector * Vector3.new(1,0,1)
        end
        if UserInputService:IsKeyDown(Enum.KeyCode.D) then
            moveDir = moveDir + cam.CFrame.RightVector * Vector3.new(1,0,1)
        end
        -- Tăng/giảm độ cao (Q/E)
        if UserInputService:IsKeyDown(Enum.KeyCode.E) then
            targetHeight = targetHeight + 0.1
        end
        if UserInputService:IsKeyDown(Enum.KeyCode.Q) then
            targetHeight = targetHeight - 0.1
        end

        bv2.Velocity = moveDir * State.Config.FlySpeed + Vector3.new(0, yCorrect, 0)
    end)
    MovementAndWorld._connections["FlyDron"] = conn
end

function MovementAndWorld.StopFlyDron()
    if MovementAndWorld._connections["FlyDron"] then
        pcall(function() MovementAndWorld._connections["FlyDron"]:Disconnect() end)
        MovementAndWorld._connections["FlyDron"] = nil
    end
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if root then
        local bv = root:FindFirstChild("FlyDronBV")
        if bv then bv:Destroy() end
        local bg = root:FindFirstChild("FlyDronBG")
        if bg then bg:Destroy() end
    end
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum then hum.PlatformStand = false end
end

-- ---- No Clip ----
local _noClipOriginals = {} -- {part => CanCollide}

function MovementAndWorld.StartNoClip()
    local char = LocalPlayer.Character
    if not char then return end
    for _, part in ipairs(char:GetDescendants()) do
        if part:IsA("BasePart") then
            _noClipOriginals[part] = part.CanCollide
            part.CanCollide = false
        end
    end
    -- Liên tục tắt CanCollide vì game có thể reset
    local conn = RunService.Stepped:Connect(function()
        if not State:IsOn("NoClip") then return end
        local char2 = LocalPlayer.Character
        if not char2 then return end
        for _, part in ipairs(char2:GetDescendants()) do
            if part:IsA("BasePart") then
                part.CanCollide = false
            end
        end
    end)
    MovementAndWorld._connections["NoClip"] = conn
end

function MovementAndWorld.StopNoClip()
    if MovementAndWorld._connections["NoClip"] then
        pcall(function() MovementAndWorld._connections["NoClip"]:Disconnect() end)
        MovementAndWorld._connections["NoClip"] = nil
    end
    -- Khôi phục CanCollide gốc
    for part, orig in pairs(_noClipOriginals) do
        pcall(function()
            if part and part.Parent then part.CanCollide = orig end
        end)
    end
    _noClipOriginals = {}
end

-- ---- Fly Air ----
function MovementAndWorld.StartFlyAir()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if hum then hum.PlatformStand = true end

    local bv = getOrCreateBodyVelocity(root, "FlyAirBV")
    local bg = getOrCreateBodyGyro(root, "FlyAirBG")

    local conn = RunService.Heartbeat:Connect(function()
        if not State:IsOn("FlyAir") then return end
        local char2 = LocalPlayer.Character
        local root2 = char2 and char2:FindFirstChild("HumanoidRootPart")
        if not root2 then return end
        local bv2 = root2:FindFirstChild("FlyAirBV")
        local bg2 = root2:FindFirstChild("FlyAirBG")
        if not bv2 then return end

        local cam = Workspace.CurrentCamera
        local speed = State.Config.FlySpeed

        -- Hướng di chuyển theo camera
        local camCF = cam.CFrame
        local forward = camCF.LookVector
        local right   = camCF.RightVector
        local up      = Vector3.new(0, 1, 0)

        local moveDir = Vector3.zero
        if UserInputService:IsKeyDown(Enum.KeyCode.W) then moveDir = moveDir + forward end
        if UserInputService:IsKeyDown(Enum.KeyCode.S) then moveDir = moveDir - forward end
        if UserInputService:IsKeyDown(Enum.KeyCode.A) then moveDir = moveDir - right end
        if UserInputService:IsKeyDown(Enum.KeyCode.D) then moveDir = moveDir + right end
        if UserInputService:IsKeyDown(Enum.KeyCode.E) then moveDir = moveDir + up end   -- Lên
        if UserInputService:IsKeyDown(Enum.KeyCode.Q) then moveDir = moveDir - up end   -- Xuống

        -- Nếu không nhấn phím: giữ nguyên vị trí (velocity = 0)
        if moveDir.Magnitude > 0 then
            bv2.Velocity = moveDir.Unit * speed
        else
            bv2.Velocity = Vector3.zero  -- Fix tự rơi khi đứng yên
        end

        -- Giữ hướng nhân vật theo camera (nằm ngang)
        if bg2 then
            bg2.CFrame = CFrame.new(root2.Position, root2.Position + camCF.LookVector)
        end
    end)
    MovementAndWorld._connections["FlyAir"] = conn
end

function MovementAndWorld.StopFlyAir()
    if MovementAndWorld._connections["FlyAir"] then
        pcall(function() MovementAndWorld._connections["FlyAir"]:Disconnect() end)
        MovementAndWorld._connections["FlyAir"] = nil
    end
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if root then
        local bv = root:FindFirstChild("FlyAirBV")
        if bv then bv:Destroy() end
        local bg = root:FindFirstChild("FlyAirBG")
        if bg then bg:Destroy() end
    end
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum then hum.PlatformStand = false end
end

-- ---- Speed ----
function MovementAndWorld.StartSpeed()
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum then
        State:SaveSnapshot("WalkSpeed_Orig", hum.WalkSpeed)
        hum.WalkSpeed = State.Config.WalkSpeed
    end
    -- Cập nhật realtime nếu config thay đổi
    local conn = RunService.Heartbeat:Connect(function()
        if not State:IsOn("Speed") then return end
        local char2 = LocalPlayer.Character
        local hum2 = char2 and char2:FindFirstChildOfClass("Humanoid")
        if hum2 then hum2.WalkSpeed = State.Config.WalkSpeed end
    end)
    MovementAndWorld._connections["Speed"] = conn
end

function MovementAndWorld.StopSpeed()
    if MovementAndWorld._connections["Speed"] then
        pcall(function() MovementAndWorld._connections["Speed"]:Disconnect() end)
        MovementAndWorld._connections["Speed"] = nil
    end
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum then
        local orig = State:GetSnapshot("WalkSpeed_Orig") or 16
        hum.WalkSpeed = orig
        State:ClearSnapshot("WalkSpeed_Orig")
    end
end

-- ---- Jumping Air ----
function MovementAndWorld.StartJumpingAir()
    -- Cho phép nhảy khi đang bay, fix kẹt bằng cách set FloorMaterial
    local conn = UserInputService.JumpRequest:Connect(function()
        if not State:IsOn("JumpingAir") then return end
        local char = LocalPlayer.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        local hum  = char and char:FindFirstChildOfClass("Humanoid")
        if not root or not hum then return end
        -- Áp lực nhảy lên khi trên không
        local bv = getOrCreateBodyVelocity(root, "JumpAirBV")
        bv.Velocity = Vector3.new(0, hum.JumpPower or 50, 0)
        -- Tự dọn sau 0.1s để không kẹt
        task.delay(0.15, function()
            if bv and bv.Parent then bv:Destroy() end
        end)
    end)
    MovementAndWorld._connections["JumpingAir"] = conn
end

function MovementAndWorld.StopJumpingAir()
    if MovementAndWorld._connections["JumpingAir"] then
        pcall(function() MovementAndWorld._connections["JumpingAir"]:Disconnect() end)
        MovementAndWorld._connections["JumpingAir"] = nil
    end
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if root then
        local bv = root:FindFirstChild("JumpAirBV")
        if bv then bv:Destroy() end
    end
end

-- ---- Night Vision ----
function MovementAndWorld.StartNightVision()
    -- Lưu snapshot ánh sáng gốc
    local lighting = Lighting
    State:SaveSnapshot("NV_Brightness",    lighting.Brightness)
    State:SaveSnapshot("NV_Ambient",       lighting.Ambient)
    State:SaveSnapshot("NV_OutdoorAmbient",lighting.OutdoorAmbient)
    State:SaveSnapshot("NV_FogEnd",        lighting.FogEnd)
    State:SaveSnapshot("NV_FogStart",      lighting.FogStart)

    -- Xóa bóng tối + sương mù
    lighting.Brightness = 2
    lighting.Ambient = Color3.fromRGB(178, 178, 178)
    lighting.OutdoorAmbient = Color3.fromRGB(178, 178, 178)
    lighting.FogEnd = 100000
    lighting.FogStart = 100000

    -- Tắt các PostEffect nặng
    for _, effect in ipairs(lighting:GetChildren()) do
        if effect:IsA("PostEffect") then
            State:SaveSnapshot("NV_Effect_"..effect.Name, effect.Enabled)
            effect.Enabled = false
        end
    end
end

function MovementAndWorld.StopNightVision()
    local lighting = Lighting
    local function restore(key, prop)
        local val = State:GetSnapshot(key)
        if val ~= nil then
            lighting[prop] = val
            State:ClearSnapshot(key)
        end
    end
    restore("NV_Brightness",     "Brightness")
    restore("NV_Ambient",        "Ambient")
    restore("NV_OutdoorAmbient", "OutdoorAmbient")
    restore("NV_FogEnd",         "FogEnd")
    restore("NV_FogStart",       "FogStart")
    -- Khôi phục PostEffect
    for _, effect in ipairs(lighting:GetChildren()) do
        if effect:IsA("PostEffect") then
            local orig = State:GetSnapshot("NV_Effect_"..effect.Name)
            if orig ~= nil then
                effect.Enabled = orig
                State:ClearSnapshot("NV_Effect_"..effect.Name)
            end
        end
    end
end

-- ---- Fix Lag ----
function MovementAndWorld.StartFixLag()
    -- Vô hiệu hóa các hiệu ứng nặng để tăng FPS
    local lighting = Lighting
    for _, effect in ipairs(lighting:GetChildren()) do
        if effect:IsA("BloomEffect") or effect:IsA("BlurEffect")
            or effect:IsA("SunRaysEffect") or effect:IsA("DepthOfFieldEffect") then
            State:SaveSnapshot("FL_Effect_"..effect.Name.."_"..effect.ClassName, effect.Enabled)
            effect.Enabled = false
        end
    end
    -- Giảm chất lượng render
    State:SaveSnapshot("FL_QualityLevel", settings().Rendering.QualityLevel)
    pcall(function()
        settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
    end)
    -- Xóa Particle/Beam/Smoke trong Workspace
    for _, obj in ipairs(Workspace:GetDescendants()) do
        if obj:IsA("ParticleEmitter") or obj:IsA("Smoke")
            or obj:IsA("Fire") or obj:IsA("Sparkles") then
            State:SaveSnapshot("FL_Particle_"..tostring(obj), obj.Enabled)
            pcall(function() obj.Enabled = false end)
        end
    end
end

function MovementAndWorld.StopFixLag()
    local lighting = Lighting
    for _, effect in ipairs(lighting:GetChildren()) do
        if effect:IsA("BloomEffect") or effect:IsA("BlurEffect")
            or effect:IsA("SunRaysEffect") or effect:IsA("DepthOfFieldEffect") then
            local key = "FL_Effect_"..effect.Name.."_"..effect.ClassName
            local orig = State:GetSnapshot(key)
            if orig ~= nil then
                effect.Enabled = orig
                State:ClearSnapshot(key)
            end
        end
    end
    local origQL = State:GetSnapshot("FL_QualityLevel")
    if origQL then
        pcall(function() settings().Rendering.QualityLevel = origQL end)
        State:ClearSnapshot("FL_QualityLevel")
    end
    -- Khôi phục Particle
    for _, obj in ipairs(Workspace:GetDescendants()) do
        if obj:IsA("ParticleEmitter") or obj:IsA("Smoke")
            or obj:IsA("Fire") or obj:IsA("Sparkles") then
            local key = "FL_Particle_"..tostring(obj)
            local orig = State:GetSnapshot(key)
            if orig ~= nil then
                pcall(function() obj.Enabled = orig end)
                State:ClearSnapshot(key)
            end
        end
    end
end

-- ============================================================
-- MODULE: UIController
-- Giao diện kéo thả, 3 tab: Main | Esp | Khác
-- ============================================================

-- Khởi động ESP render loop ngay từ đầu (chỉ hiển thị khi tính năng ON)
EspEngine.StartRenderLoop()

-- Utility tạo button
local function createButton(parent, text, color, size, pos)
    local btn = Instance.new("TextButton")
    btn.Text = text
    btn.BackgroundColor3 = color or Color3.fromRGB(50, 50, 60)
    btn.TextColor3 = Color3.fromRGB(240, 240, 240)
    btn.Size = size or UDim2.new(1, -10, 0, 28)
    btn.Position = pos or UDim2.new(0, 5, 0, 0)
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 12
    btn.AutoButtonColor = true
    btn.BorderSizePixel = 0
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 6)
    corner.Parent = btn
    btn.Parent = parent
    return btn
end

-- Utility tạo label
local function createLabel(parent, text, pos, size)
    local lbl = Instance.new("TextLabel")
    lbl.Text = text
    lbl.BackgroundTransparency = 1
    lbl.TextColor3 = Color3.fromRGB(200, 200, 200)
    lbl.Font = Enum.Font.Gotham
    lbl.TextSize = 11
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Size = size or UDim2.new(1, 0, 0, 20)
    lbl.Position = pos or UDim2.new(0, 0, 0, 0)
    lbl.Parent = parent
    return lbl
end

-- Tạo số input
local function createNumberInput(parent, label, default, minVal, maxVal, onChange)
    local frame = Instance.new("Frame")
    frame.Size = UDim2.new(1, -10, 0, 44)
    frame.BackgroundTransparency = 1
    frame.Parent = parent

    local lbl = createLabel(frame, label, UDim2.new(0, 5, 0, 0), UDim2.new(0.6, 0, 0, 20))

    local box = Instance.new("TextBox")
    box.Text = tostring(default)
    box.Size = UDim2.new(0, 70, 0, 22)
    box.Position = UDim2.new(1, -75, 0, 11)
    box.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
    box.TextColor3 = Color3.fromRGB(240, 240, 240)
    box.Font = Enum.Font.Gotham
    box.TextSize = 12
    box.BorderSizePixel = 0
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 4)
    corner.Parent = box
    box.Parent = frame

    box.FocusLost:Connect(function()
        local val = tonumber(box.Text)
        if val then
            val = math.clamp(val, minVal or -9999, maxVal or 9999)
            box.Text = tostring(val)
            if onChange then onChange(val) end
        else
            box.Text = tostring(default)
        end
    end)
    return frame
end

-- ===== Xây dựng GUI =====
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "DebugGUI"
ScreenGui.ResetOnSpawn = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.Parent = LocalPlayer.PlayerGui

-- Frame chính (kéo thả được)
local MainFrame = Instance.new("Frame")
MainFrame.Name = "MainFrame"
MainFrame.Size = UDim2.new(0, 280, 0, 420)
MainFrame.Position = UDim2.new(0, 20, 0.5, -210)
MainFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
MainFrame.BorderSizePixel = 0
MainFrame.ClipsDescendants = true
MainFrame.Parent = ScreenGui

local mainCorner = Instance.new("UICorner")
mainCorner.CornerRadius = UDim.new(0, 10)
mainCorner.Parent = MainFrame

-- Thanh tiêu đề (kéo thả)
local TitleBar = Instance.new("Frame")
TitleBar.Name = "TitleBar"
TitleBar.Size = UDim2.new(1, 0, 0, 36)
TitleBar.BackgroundColor3 = Color3.fromRGB(35, 35, 50)
TitleBar.BorderSizePixel = 0
TitleBar.Parent = MainFrame

local titleCorner = Instance.new("UICorner")
titleCorner.CornerRadius = UDim.new(0, 10)
titleCorner.Parent = TitleBar

local TitleLabel = Instance.new("TextLabel")
TitleLabel.Text = "⚙ Debug GUI"
TitleLabel.Size = UDim2.new(1, -70, 1, 0)
TitleLabel.Position = UDim2.new(0, 10, 0, 0)
TitleLabel.BackgroundTransparency = 1
TitleLabel.TextColor3 = Color3.fromRGB(255, 220, 80)
TitleLabel.Font = Enum.Font.GothamBold
TitleLabel.TextSize = 14
TitleLabel.TextXAlignment = Enum.TextXAlignment.Left
TitleLabel.Parent = TitleBar

-- Nút thu gọn/mở rộng
local MinBtn = Instance.new("TextButton")
MinBtn.Text = "−"
MinBtn.Size = UDim2.new(0, 28, 0, 28)
MinBtn.Position = UDim2.new(1, -32, 0, 4)
MinBtn.BackgroundColor3 = Color3.fromRGB(255, 180, 0)
MinBtn.TextColor3 = Color3.fromRGB(0, 0, 0)
MinBtn.Font = Enum.Font.GothamBold
MinBtn.TextSize = 16
MinBtn.BorderSizePixel = 0
local minCorner = Instance.new("UICorner")
minCorner.CornerRadius = UDim.new(0, 6)
minCorner.Parent = MinBtn
MinBtn.Parent = TitleBar

-- Trạng thái thu gọn
local isMinimized = false
local normalHeight = 420
MinBtn.MouseButton1Click:Connect(function()
    isMinimized = not isMinimized
    if isMinimized then
        MainFrame.Size = UDim2.new(0, 280, 0, 36)
        MinBtn.Text = "+"
    else
        MainFrame.Size = UDim2.new(0, 280, 0, normalHeight)
        MinBtn.Text = "−"
    end
end)

-- ---- Kéo thả TitleBar ----
local dragging = false
local dragInput, dragStart, startPos

TitleBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPos = MainFrame.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                dragging = false
            end
        end)
    end
end)

TitleBar.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch then
        dragInput = input
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if dragging and input == dragInput then
        local delta = input.Position - dragStart
        MainFrame.Position = UDim2.new(
            startPos.X.Scale,
            startPos.X.Offset + delta.X,
            startPos.Y.Scale,
            startPos.Y.Offset + delta.Y
        )
    end
end)

-- ---- Tab buttons ----
local TabBar = Instance.new("Frame")
TabBar.Size = UDim2.new(1, 0, 0, 30)
TabBar.Position = UDim2.new(0, 0, 0, 36)
TabBar.BackgroundColor3 = Color3.fromRGB(28, 28, 40)
TabBar.BorderSizePixel = 0
TabBar.Parent = MainFrame

local tabNames = {"Main", "Esp", "Khác"}
local tabBtns = {}
local tabFrames = {}
local activeTab = "Main"

for i, name in ipairs(tabNames) do
    local btn = Instance.new("TextButton")
    btn.Text = name
    btn.Size = UDim2.new(1/3, -2, 1, -4)
    btn.Position = UDim2.new((i-1)/3, 1, 0, 2)
    btn.BackgroundColor3 = i == 1
        and Color3.fromRGB(80, 80, 120)
        or Color3.fromRGB(40, 40, 55)
    btn.TextColor3 = Color3.fromRGB(220, 220, 220)
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 12
    btn.BorderSizePixel = 0
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, 6)
    c.Parent = btn
    btn.Parent = TabBar
    tabBtns[name] = btn
end

-- Content area với ScrollingFrame cho từng tab
local ContentArea = Instance.new("Frame")
ContentArea.Size = UDim2.new(1, 0, 1, -66)
ContentArea.Position = UDim2.new(0, 0, 0, 66)
ContentArea.BackgroundTransparency = 1
ContentArea.ClipsDescendants = true
ContentArea.Parent = MainFrame

for _, name in ipairs(tabNames) do
    local sf = Instance.new("ScrollingFrame")
    sf.Name = name
    sf.Size = UDim2.new(1, 0, 1, 0)
    sf.Position = UDim2.new(0, 0, 0, 0)
    sf.BackgroundTransparency = 1
    sf.ScrollBarThickness = 4
    sf.ScrollBarImageColor3 = Color3.fromRGB(100, 100, 150)
    sf.CanvasSize = UDim2.new(0, 0, 0, 0)
    sf.AutomaticCanvasSize = Enum.AutomaticSize.Y
    sf.Visible = (name == "Main")
    sf.Parent = ContentArea
    tabFrames[name] = sf

    local layout = Instance.new("UIListLayout")
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, 4)
    layout.Parent = sf

    local padding = Instance.new("UIPadding")
    padding.PaddingLeft = UDim.new(0, 5)
    padding.PaddingRight = UDim.new(0, 5)
    padding.PaddingTop = UDim.new(0, 5)
    padding.Parent = sf
end

-- Chuyển tab
for _, name in ipairs(tabNames) do
    tabBtns[name].MouseButton1Click:Connect(function()
        activeTab = name
        for _, n in ipairs(tabNames) do
            tabFrames[n].Visible = (n == name)
            tabBtns[n].BackgroundColor3 = (n == name)
                and Color3.fromRGB(80, 80, 120)
                or Color3.fromRGB(40, 40, 55)
        end
    end)
end

-- ============================================================
-- Hàm tạo toggle button (ON/OFF) tích hợp callback
-- ============================================================
local function createToggle(parent, label, feature, onEnable, onDisable, layoutOrder)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, -10, 0, 32)
    row.BackgroundColor3 = Color3.fromRGB(30, 30, 42)
    row.BorderSizePixel = 0
    row.LayoutOrder = layoutOrder or 0
    local rc = Instance.new("UICorner")
    rc.CornerRadius = UDim.new(0, 6)
    rc.Parent = row
    row.Parent = parent

    local lbl = Instance.new("TextLabel")
    lbl.Text = label
    lbl.Size = UDim2.new(1, -70, 1, 0)
    lbl.Position = UDim2.new(0, 8, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.TextColor3 = Color3.fromRGB(220, 220, 220)
    lbl.Font = Enum.Font.Gotham
    lbl.TextSize = 12
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = row

    local toggleBtn = Instance.new("TextButton")
    toggleBtn.Text = "OFF"
    toggleBtn.Size = UDim2.new(0, 56, 0, 22)
    toggleBtn.Position = UDim2.new(1, -62, 0.5, -11)
    toggleBtn.BackgroundColor3 = Color3.fromRGB(180, 60, 60)
    toggleBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    toggleBtn.Font = Enum.Font.GothamBold
    toggleBtn.TextSize = 11
    toggleBtn.BorderSizePixel = 0
    local tc = Instance.new("UICorner")
    tc.CornerRadius = UDim.new(0, 5)
    tc.Parent = toggleBtn
    toggleBtn.Parent = row

    toggleBtn.MouseButton1Click:Connect(function()
        local isOn = State:Toggle(feature)
        if isOn then
            toggleBtn.Text = "ON"
            toggleBtn.BackgroundColor3 = Color3.fromRGB(60, 180, 80)
            if onEnable then pcall(onEnable) end
        else
            toggleBtn.Text = "OFF"
            toggleBtn.BackgroundColor3 = Color3.fromRGB(180, 60, 60)
            if onDisable then pcall(onDisable) end
        end
    end)

    return row
end

-- ============================================================
-- Tạo nội dung TAB MAIN
-- ============================================================
local mainTab = tabFrames["Main"]

createToggle(mainTab, "Tele Dron", "TeleDron",
    CombatEngine.StartTeleDron,
    CombatEngine.StopTeleDron, 1)

-- Input SafeHeight cho Tele Dron
local droneHeightInput = createNumberInput(mainTab,
    "Drone Height Offset", State.Config.DroneHeightOffset, 1, 50,
    function(v) State.Config.DroneHeightOffset = v end)
droneHeightInput.LayoutOrder = 2
droneHeightInput.Parent = mainTab

createToggle(mainTab, "Hitbox All Mod", "HitboxAllMod",
    CombatEngine.StartHitboxAllMod,
    CombatEngine.StopHitboxAllMod, 3)

local hitboxSizeInput = createNumberInput(mainTab,
    "Hitbox Size", State.Config.HitboxSize, 1, 100,
    function(v) State.Config.HitboxSize = v end)
hitboxSizeInput.LayoutOrder = 4
hitboxSizeInput.Parent = mainTab

createToggle(mainTab, "Tele Kill", "TeleKill",
    CombatEngine.StartTeleKill,
    CombatEngine.StopTeleKill, 5)

createToggle(mainTab, "Aimbot", "Aimbot",
    CombatEngine.StartAimbot,
    CombatEngine.StopAimbot, 6)

createToggle(mainTab, "All Mod Im (Freeze Mob)", "AllModIm",
    CombatEngine.StartAllModIm,
    CombatEngine.StopAllModIm, 7)

createToggle(mainTab, "Model Độn Thổ", "ModelDonTho",
    CombatEngine.StartModelDonTho,
    CombatEngine.StopModelDonTho, 8)

local donThoInput = createNumberInput(mainTab,
    "Độ Sâu (studs)", State.Config.DonThoDepth, -100, -1,
    function(v) State.Config.DonThoDepth = v end)
donThoInput.LayoutOrder = 9
donThoInput.Parent = mainTab

createToggle(mainTab, "Model Head Down", "ModelHeadDown",
    CombatEngine.StartModelHeadDown,
    CombatEngine.StopModelHeadDown, 10)

local headDownInput = createNumberInput(mainTab,
    "Depth (studs)", State.Config.HeadDownDepth, -50, -1,
    function(v) State.Config.HeadDownDepth = v end)
headDownInput.LayoutOrder = 11
headDownInput.Parent = mainTab

createToggle(mainTab, "Player Barrier", "PlayerBarrier",
    CombatEngine.StartPlayerBarrier,
    CombatEngine.StopPlayerBarrier, 12)

local barrierSizeInput = createNumberInput(mainTab,
    "Barrier Size", State.Config.BarrierSize, 2, 50,
    function(v) State.Config.BarrierSize = v end)
barrierSizeInput.LayoutOrder = 13
barrierSizeInput.Parent = mainTab

createToggle(mainTab, "Long Legs", "LongLegs",
    CombatEngine.StartLongLegs,
    CombatEngine.StopLongLegs, 14)

local longLegsInput = createNumberInput(mainTab,
    "Leg Depth (studs)", State.Config.LongLegsDepth, -100, -1,
    function(v) State.Config.LongLegsDepth = v end)
longLegsInput.LayoutOrder = 15
longLegsInput.Parent = mainTab

createToggle(mainTab, "Long Head", "LongHead",
    CombatEngine.StartLongHead,
    CombatEngine.StopLongHead, 16)

local longHeadInput = createNumberInput(mainTab,
    "Head Height", State.Config.LongHeadHeight, 1, 50,
    function(v) State.Config.LongHeadHeight = v end)
longHeadInput.LayoutOrder = 17
longHeadInput.Parent = mainTab

-- Scan Range chung
local scanRangeInput = createNumberInput(mainTab,
    "Scan Range (studs)", State.Config.ScanRange, 10, 500,
    function(v)
        State.Config.ScanRange = v
        Scanner._lastScanTick = 0 -- Force rescan
    end)
scanRangeInput.LayoutOrder = 18
scanRangeInput.Parent = mainTab

-- ============================================================
-- Tạo nội dung TAB ESP
-- ============================================================
local espTab = tabFrames["Esp"]

local function espToggle(label, feature, lo)
    createToggle(espTab, label, feature,
        function()
            if not EspEngine._connections["Render"] then
                EspEngine.StartRenderLoop()
            end
        end,
        function()
            -- Tắt tính năng ESP cụ thể, loop vẫn chạy để cleanup
        end, lo)
end

espToggle("Esp Line (Đường kẻ)", "EspLine", 1)
espToggle("Esp Box (Khung bao)", "EspBox", 2)
espToggle("Esp Name (Tên mob)", "EspName", 3)
espToggle("Esp Distance (Khoảng cách)", "EspDistance", 4)
espToggle("Esp Hologram (Xuyên tường)", "EspHologram", 5)

-- ============================================================
-- Tạo nội dung TAB KHÁC
-- ============================================================
local otherTab = tabFrames["Khác"]

createToggle(otherTab, "Fly Down (Nằm ngửa)", "FlyDown",
    MovementAndWorld.StartFlyDown,
    MovementAndWorld.StopFlyDown, 1)

createToggle(otherTab, "Fly Dron (Úp mặt xuống)", "FlyDron",
    MovementAndWorld.StartFlyDron,
    MovementAndWorld.StopFlyDron, 2)

local flyDronHeightInput = createNumberInput(otherTab,
    "Fly Dron Height", State.Config.FlyDronHeight, 1, 100,
    function(v) State.Config.FlyDronHeight = v end)
flyDronHeightInput.LayoutOrder = 3
flyDronHeightInput.Parent = otherTab

createToggle(otherTab, "No Clip (Xuyên tường)", "NoClip",
    MovementAndWorld.StartNoClip,
    MovementAndWorld.StopNoClip, 4)

createToggle(otherTab, "Fly Air (Bay tự do)", "FlyAir",
    MovementAndWorld.StartFlyAir,
    MovementAndWorld.StopFlyAir, 5)

local flySpeedInput = createNumberInput(otherTab,
    "Fly Speed", State.Config.FlySpeed, 1, 200,
    function(v) State.Config.FlySpeed = v end)
flySpeedInput.LayoutOrder = 6
flySpeedInput.Parent = otherTab

createToggle(otherTab, "Speed (Tốc độ)", "Speed",
    MovementAndWorld.StartSpeed,
    MovementAndWorld.StopSpeed, 7)

local speedInput = createNumberInput(otherTab,
    "Walk Speed", State.Config.WalkSpeed, 1, 500,
    function(v)
        State.Config.WalkSpeed = v
        if State:IsOn("Speed") then
            local char = LocalPlayer.Character
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            if hum then hum.WalkSpeed = v end
        end
    end)
speedInput.LayoutOrder = 8
speedInput.Parent = otherTab

createToggle(otherTab, "Jumping Air (Nhảy trên không)", "JumpingAir",
    MovementAndWorld.StartJumpingAir,
    MovementAndWorld.StopJumpingAir, 9)

createToggle(otherTab, "Night Vision (Nhìn đêm)", "NightVision",
    MovementAndWorld.StartNightVision,
    MovementAndWorld.StopNightVision, 10)

createToggle(otherTab, "Fix Lag (Tăng FPS)", "FixLag",
    MovementAndWorld.StartFixLag,
    MovementAndWorld.StopFixLag, 11)

-- ============================================================
-- Dọn dẹp hoàn toàn khi nhân vật respawn
-- ============================================================
LocalPlayer.CharacterAdded:Connect(function(char)
    -- Tắt tất cả tính năng và dọn dẹp
    State.States.TeleDron = false
    State.States.HitboxAllMod = false
    State.States.TeleKill = false
    State.States.Aimbot = false
    State.States.AllModIm = false
    State.States.ModelDonTho = false
    State.States.ModelHeadDown = false
    State.States.PlayerBarrier = false
    State.States.LongLegs = false
    State.States.LongHead = false
    State.States.FlyDown = false
    State.States.FlyDron = false
    State.States.NoClip = false
    State.States.FlyAir = false
    State.States.JumpingAir = false

    CombatEngine.StopTeleDron()
    CombatEngine.StopHitboxAllMod()
    CombatEngine.StopTeleKill()
    CombatEngine.StopAimbot()
    CombatEngine.StopAllModIm()
    CombatEngine.StopModelDonTho()
    CombatEngine.StopModelHeadDown()
    CombatEngine.StopPlayerBarrier()
    CombatEngine.StopLongLegs()
    CombatEngine.StopLongHead()
    MovementAndWorld.StopFlyDown()
    MovementAndWorld.StopFlyDron()
    MovementAndWorld.StopNoClip()
    MovementAndWorld.StopFlyAir()
    MovementAndWorld.StopJumpingAir()

    -- Scanner reset cache
    Scanner._cache = {}
    Scanner._lastScanTick = 0

    -- Chờ nhân vật load xong rồi chạy lại
    char:WaitForChild("HumanoidRootPart", 10)
end)

-- ============================================================
-- Phím tắt: RightShift để ẩn/hiện GUI
-- ============================================================
UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == Enum.KeyCode.RightShift then
        MainFrame.Visible = not MainFrame.Visible
    end
end)

print("[DebugGUI] Đã tải xong. Nhấn RightShift để ẩn/hiện GUI.")
print("[DebugGUI] Phím bay: W/S/A/D = di chuyển, E = lên, Q = xuống")
