#include "music_player.h"

music_player_t music_player_create(music_track_t *first)
{
    return (music_player_t){.first=first,.wanted=first,
                            .sequential=true,.request=first!=NULL};
}
void music_player_step(music_player_t *player,bool next)
{
    if(!player->wanted || player->error) return;
    music_track_t *target=player->wanted->next;
    if(!next) {
        target=player->first;
        while(target->next && target->next!=player->wanted) target=target->next;
    }
    player->wanted=target ? target : player->first;
    player->request=true;
}
void music_player_tick(music_player_t *player,const music_transport_t *io)
{
    if(player->error || !player->first) return;
    uint32_t status=io->status(io->context);
    if(status&MUSIC_TRANSFER_ERROR) {player->error=MUSIC_TRANSFER_ERROR;return;}
    if(status&MUSIC_BUSY) return;
    if(player->pending) {
        player->current=player->submitted;
        player->pending=false;
    }
    if((status&MUSIC_FINISHED) && !player->request) {
        if(player->sequential) music_player_step(player,true);
        else player->request=true;
    }
    if(!player->request) return;
    player->submitted=player->wanted;
    io->submit(io->context,player->submitted);
    player->request=false;
    player->pending=true;
}
