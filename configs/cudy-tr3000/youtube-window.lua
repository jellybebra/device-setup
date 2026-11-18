-- Dedicated nfqws2 queue, with reassembly disabled. Feed client packets for
-- the entire selected TCP flow, including SYN, and the server's SYN-ACK.
-- The client keeps using its original scale, even after the window opens.
local serial_modulus = 4294967296

local function offered_scale(tcp)
    local index = find_tcp_option(tcp.options, TCP_KIND_SCALE)
    if not index then return end
    local option = tcp.options[index]
    if not option.data or #option.data ~= 1 then return end
    local scale = string.byte(option.data)
    if scale <= 14 then return option, scale end
end

function youtube_window(ctx, desync)
    local tcp = desync.dis.tcp
    if not tcp or not desync.track or bitand(tcp.th_flags, TH_RST) ~= 0 then
        return VERDICT_PASS
    end

    local flow = desync.track.lua_state
    local state = flow.youtube_window
    local flags = bitand(tcp.th_flags, TH_SYN + TH_ACK)
    if desync.outgoing and flags == TH_SYN then
        if state and state.client_isn ~= tcp.th_seq then
            flow.youtube_window = nil
            state = nil
        end
        local option, scale = offered_scale(tcp)
        if not option then return VERDICT_PASS end
        if not state then
            local wire_scale = math.min(scale, 1)
            state = {
                client_isn = tcp.th_seq,
                syn_bytes = #(desync.dis.payload or ""),
                wire_scale = wire_scale,
                multiplier = 2 ^ (scale - wire_scale),
            }
            flow.youtube_window = state
        end
        local window = math.min(tcp.th_win, 1)
        if scale == state.wire_scale and tcp.th_win == window then return VERDICT_PASS end
        option.data = string.char(state.wire_scale)
        tcp.th_win = window
        return VERDICT_MODIFY
    end

    if not state then return VERDICT_PASS end
    if not desync.outgoing then
        if flags == TH_SYN + TH_ACK and state.server_isn == nil then
            -- TCP Fast Open can acknowledge data sent in the SYN.
            local syn_data_acked = (tcp.th_ack - state.client_isn - 1) % serial_modulus
            if syn_data_acked <= state.syn_bytes then
                state.server_isn = tcp.th_seq
                state.scaling = offered_scale(tcp) ~= nil
            end
        end
        return VERDICT_PASS
    end
    if flags ~= TH_ACK or not state.scaling then return VERDICT_PASS end

    if not state.opened then
        local acknowledged = (tcp.th_ack - state.server_isn - 1) % serial_modulus
        state.opened = acknowledged > 0 and acknowledged < serial_modulus / 2
    end
    -- A zero advertised by the client always stays zero, including at startup.
    local original = tcp.th_win
    local window = state.opened and math.min(65535, original * state.multiplier)
        or math.min(original, 1)
    if window == original then return VERDICT_PASS end
    tcp.th_win = window
    return VERDICT_MODIFY
end
