#ifndef V2DPI_WSSIZE_RAMP_H
#define V2DPI_WSSIZE_RAMP_H

#include <stdbool.h>
#include <stdint.h>
#include <netinet/in.h>
#include <netinet/tcp.h>

struct wssize_ramp_state {
	bool negotiated;
	bool opened;
	uint8_t shift;
};

// Called once per original outgoing packet, before replay or segmentation.
// The client's kernel keeps its real scale for the lifetime of the socket.
// After progress, translate every advertised window to the scale seen by the peer.
static inline bool wssize_ramp_apply(struct wssize_ramp_state *state,
	bool enabled, struct tcphdr *tcp, uint8_t *syn_scale, uint32_t server_isn)
{
	if (tcp->th_flags & TH_RST)
		return false;

	if (tcp->th_flags & TH_SYN) {
		if ((!enabled && !state->negotiated) || !syn_scale || *syn_scale > 14 || (tcp->th_flags & TH_ACK))
			return false;
		const uint8_t real_scale = *syn_scale;
		const uint8_t wire_scale = real_scale > 1 ? 1 : real_scale;
		state->negotiated = true;
		state->shift = real_scale - wire_scale;
		*syn_scale = wire_scale;
		tcp->th_win = htons(1);
		return true;
	}

	// A host rule first matched on ClientHello cannot change an existing negotiation.
	if (!state->negotiated || !(tcp->th_flags & TH_ACK))
		return false;

	// Unsigned serial arithmetic also covers a server ISN near 2^32.
	const uint32_t acknowledged = ntohl(tcp->th_ack) - server_isn - 1;
	if (acknowledged && acknowledged < UINT32_C(0x80000000))
		state->opened = true;

	const uint32_t original = ntohs(tcp->th_win);
	uint32_t window = state->opened ? original << state->shift : 1;
	if (window > UINT16_MAX)
		window = UINT16_MAX;
	if (window == original)
		return false;
	tcp->th_win = htons((uint16_t)window);
	return true;
}
#endif
