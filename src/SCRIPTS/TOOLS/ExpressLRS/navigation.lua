---- #########################################################################
---- # Navigation Module: Folder navigation stack and methods             #
---- # Zero dependencies on other modules                                 #
---- #########################################################################

local Navigation = {
  stack = {},
  -- Navigation entry type constants (integers to save RAM vs strings)
  TYPE_FOLDER = 0,
  TYPE_DEVICE = 1,
  -- Synthetic folder IDs
  FOLDER_OTHER_DEVICES = -1,
}

function Navigation.getCurrent()
  local top = Navigation.stack[#Navigation.stack]
  return top and top.id or nil -- nil if at root (or device root)
end

function Navigation.isAtRoot()
  return #Navigation.stack == 0
end

-- Check if the user has navigated into a device (for hiding "Other Devices")
function Navigation.hasDeviceEntry()
  for _, entry in ipairs(Navigation.stack) do
    if entry.type == Navigation.TYPE_DEVICE then
      return true
    end
  end
  return false
end

-- viewState: optional table of UI state to preserve (e.g. cursor position).
-- Merged into the nav entry so the UI can restore it on goBack().
function Navigation.openFolder(folderId, folderName, viewState)
  local entry = {
    type = Navigation.TYPE_FOLDER,
    id = folderId,
    name = folderName,
  }
  if viewState then
    for k, v in pairs(viewState) do
      entry[k] = v
    end
  end
  Navigation.stack[#Navigation.stack + 1] = entry
end

function Navigation.openDevice(deviceName, prevDeviceId, viewState)
  local entry = {
    type = Navigation.TYPE_DEVICE,
    id = nil,
    name = deviceName,
    prevDeviceId = prevDeviceId,
  }
  if viewState then
    for k, v in pairs(viewState) do
      entry[k] = v
    end
  end
  Navigation.stack[#Navigation.stack + 1] = entry
end

function Navigation.goBack()
  if #Navigation.stack > 0 then
    local entry = Navigation.stack[#Navigation.stack]
    Navigation.stack[#Navigation.stack] = nil
    return entry
  end
  return nil
end

function Navigation.reset()
  Navigation.stack = {}
end

return Navigation
