GHUtil = {}

function GHUtil.trim1(s)
  return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

function GHUtil.strsplit(sep, str)
	local result = {}
	for w in string.gfind(str, "([^"..sep.."]+)"..sep.."?") do
		table.insert(result, w)
	end
	return unpack(result)
end

function GHUtil.strsplit2(sep, str)
    return string.gfind(str, "([^"..sep.."]+)"..sep.."?")
end

function GHUtil.containsValue(table, element)
 	for _, value in pairs(table) do
		if value == element then
			return true
		end
	end
	return false
end

function GHUtil.copyTable(orig)
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        copy = {}
        for orig_key, orig_value in pairs(orig) do
            copy[orig_key] = orig_value
        end
    else -- number, string, boolean, etc
        copy = orig
    end
    return copy
end