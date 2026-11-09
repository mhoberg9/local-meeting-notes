#include <whisper/whisper.h>
#include <algorithm>
#include <cstdint>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

static uint16_t u16(const unsigned char *b) { return uint16_t(b[0]) | uint16_t(b[1]) << 8; }
static uint32_t u32(const unsigned char *b) { return uint32_t(u16(b)) | uint32_t(u16(b + 2)) << 16; }
static std::vector<float> read_wav(const std::string &path) {
    std::ifstream in(path, std::ios::binary);
    unsigned char header[12];
    if (!in.read(reinterpret_cast<char *>(header),12) || std::string(reinterpret_cast<char *>(header),4)!="RIFF" || std::string(reinterpret_cast<char *>(header+8),4)!="WAVE")
        throw std::runtime_error("Not a readable WAV file");
    bool format=false;
    while (in) {
        unsigned char chunk[8]; if (!in.read(reinterpret_cast<char *>(chunk),8)) break;
        std::string name(reinterpret_cast<char *>(chunk),4); uint32_t length=u32(chunk+4);
        if (name=="fmt ") {
            if (length<16 || length>65536) throw std::runtime_error("Invalid WAV format");
            std::vector<unsigned char> bytes(length); if(!in.read(reinterpret_cast<char *>(bytes.data()),length)) break;
            format=u16(bytes.data())==1 && u16(bytes.data()+2)==1 && u32(bytes.data()+4)==16000 && u16(bytes.data()+14)==16;
            if (length & 1) in.ignore(1);
        } else if (name=="data") {
            if (!format || length==0 || length%2 || length>16000ULL*2*60*60*8) throw std::runtime_error("Expected 16 kHz mono PCM audio, up to eight hours");
            auto start=in.tellg(); in.seekg(0,std::ios::end); auto end=in.tellg(); in.seekg(start);
            if(end-start < std::streamoff(length)) throw std::runtime_error("Truncated WAV recording");
            std::vector<float> samples(length/2);
            unsigned char block[32768]; size_t written=0;
            while(written<samples.size()) {
                size_t count=std::min<size_t>(sizeof(block)/2,samples.size()-written);
                if(!in.read(reinterpret_cast<char *>(block),count*2)) throw std::runtime_error("Could not read the complete recording");
                for(size_t i=0;i<count;i++) samples[written+i]=int16_t(u16(block+i*2))/32768.0f;
                written+=count;
            }
            return samples;
        } else in.seekg(uint64_t(length)+(length&1),std::ios::cur);
    }
    throw std::runtime_error("WAV audio data is missing");
}
static std::string stamp(int64_t ticks) {
    int64_t ms=ticks*10; std::ostringstream s;
    s<<std::setfill('0')<<std::setw(2)<<ms/3600000<<":"<<std::setw(2)<<(ms/60000)%60<<":"<<std::setw(2)<<(ms/1000)%60<<","<<std::setw(3)<<ms%1000;
    return s.str();
}
struct Output { std::ofstream text, srt; bool failed=false; };
static void segment(whisper_context *ctx, whisper_state *, int count, void *user) {
    auto &out=*static_cast<Output *>(user); int total=whisper_full_n_segments(ctx);
    for(int i=total-count;i<total;i++) {
        const char *text=whisper_full_get_segment_text(ctx,i);
        out.text<<text<<"\n";
        out.srt<<i+1<<"\n"<<stamp(whisper_full_get_segment_t0(ctx,i))<<" --> "<<stamp(whisper_full_get_segment_t1(ctx,i))<<"\n"<<text<<"\n\n";
    }
    out.text.flush(); out.srt.flush(); out.failed=!out.text.good() || !out.srt.good();
}
int main(int argc,char **argv) {
    try {
        if(argc==3 && std::string(argv[1])=="--check-model") {
            auto p=whisper_context_default_params(); p.use_gpu=true;
            auto *ctx=whisper_init_from_file_with_params(argv[2],p);
            if(!ctx) { p.use_gpu=false; ctx=whisper_init_from_file_with_params(argv[2],p); }
            if(!ctx) throw std::runtime_error("The bundled model could not be initialized");
            whisper_free(ctx); std::cout<<"Bundled speech model initialized successfully.\n"; return 0;
        }
        if(argc!=5) throw std::runtime_error("Usage: transcribe-helper MODEL WAV de|en OUTPUT_PREFIX");
        std::string language=argv[3]; if(language!="de" && language!="en") throw std::runtime_error("Choose German or English");
        auto samples=read_wav(argv[2]);
        auto options=whisper_context_default_params(); options.use_gpu=true;
        whisper_context *ctx=whisper_init_from_file_with_params(argv[1],options);
        if(!ctx) { options.use_gpu=false; ctx=whisper_init_from_file_with_params(argv[1],options); }
        if(!ctx) throw std::runtime_error("Could not load the local speech model");
        Output output; output.text.open(std::string(argv[4])+".txt"); output.srt.open(std::string(argv[4])+".srt");
        if(!output.text || !output.srt) { whisper_free(ctx); throw std::runtime_error("Could not create transcript files"); }
        auto params=whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH);
        params.language=argv[3]; params.translate=false; params.n_threads=std::max(1u,std::min(8u,std::thread::hardware_concurrency()));
        params.print_realtime=false; params.print_timestamps=false; params.print_progress=true;
        params.new_segment_callback=segment; params.new_segment_callback_user_data=&output;
        int result=whisper_full(ctx,params,samples.data(),int(samples.size()));
        whisper_free(ctx); output.text.close(); output.srt.close();
        if(result!=0 || output.failed) throw std::runtime_error("Transcription did not finish; audio is kept");
        return 0;
    } catch(const std::exception &e) { std::cerr<<e.what()<<"\n"; return 1; }
}

