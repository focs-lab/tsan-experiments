#include <iostream>
#include <thread>
#include <filesystem>
#include <vector>
#include <set>
#include <fstream>
#include <sstream>
#include <unordered_map>
#include <cinttypes>
#include <chrono>
#include <algorithm>

typedef uint64_t AddressT;
typedef uint32_t ThreadIdT;

using std::chrono::high_resolution_clock;
using std::chrono::duration_cast;
using std::chrono::milliseconds;


struct LogUnit {
  std::string AccessType = {};
  std::string Source     = {};
  AddressT Address       = 0;
  ThreadIdT ThreadId     = 0;
  uint32_t AccessSize    = 0;
};


struct AccessStats {
  std::set<ThreadIdT> ThreadIds = {};
  uint64_t ReadCount  = 0;
  uint64_t WriteCount = 0;
};


struct LogStats {
  std::unordered_map<std::string, AccessStats> Sources = {};
  std::unordered_map<AddressT, AccessStats> Addresses  = {};
  std::set <std::string> Operations = {};
  std::set<AddressT> SWMRAddresses  = {};

  void AppendThreadId(const std::string &Source,
                      const AddressT Address,
                      ThreadIdT ThreadId) {
    Sources[Source].ThreadIds.insert(ThreadId);
    Addresses[Address].ThreadIds.insert(ThreadId);
  }

  void AppendRead(const std::string &Source,
                  const AddressT Address) {
    Sources[Source].ReadCount++;
    Addresses[Address].ReadCount++;
  }

  void AppendWrite(const std::string &Source,
                   const AddressT Address) {
    Sources[Source].WriteCount++;
    Addresses[Address].WriteCount++;
  }

  void Append(LogUnit Unit) {
    Operations.insert(Unit.AccessType);
    AppendThreadId(Unit.Source, Unit.Address, Unit.ThreadId);

    if (Unit.AccessType.find("read") != std::string::npos)
      AppendRead(Unit.Source, Unit.Address);
    else
      AppendWrite(Unit.Source, Unit.Address);
  }
};


LogUnit ParseLine(const std::string &Line) {
  LogUnit ParsedUnit = {};
  std::istringstream LineStream(Line);

  LineStream.ignore(3);   // Skipping " > "

  LineStream >> ParsedUnit.AccessType;
  LineStream >> std::hex >> ParsedUnit.Address;
  LineStream >> ParsedUnit.AccessSize;
  LineStream >> ParsedUnit.ThreadId;
  LineStream >> ParsedUnit.Source;

  return ParsedUnit;
}


void HandleLog(const std::string &LogPath,
               const uintmax_t LogOffset,
               const uintmax_t LogBytesToHandle,
               LogStats *Stats) {
  std::ifstream LogFile(LogPath, std::ios::in);
  std::string Line;

  if (LogOffset > 0) {
    LogFile.seekg(LogOffset);
    std::getline(LogFile, Line);  // Just go to the newline
  }

  // We don't know, if we're started reading from the newline or not,
  // (excluding the first block) so if block ends with the newline,
  // we also need to handle the next line
  // Hence, '<=' is right operator here
  while (LogFile.tellg() <= LogOffset + LogBytesToHandle &&
         std::getline(LogFile, Line)) {
    if (Line.length() > 2 && Line[1] == '>')
      Stats->Append(ParseLine(Line));
  }
}


void MergeStats(LogStats &Final, LogStats &Part) {
  for (auto SourceStats : Part.Sources) {
    auto Key = SourceStats.first;
    auto Stats = SourceStats.second;

    Final.Sources[Key].ReadCount += Stats.ReadCount;
    Final.Sources[Key].WriteCount += Stats.WriteCount;
    Final.Sources[Key].ThreadIds.insert(Stats.ThreadIds.begin(), Stats.ThreadIds.end());
  }

  for (auto SourceStats : Part.Addresses) {
    auto Key = SourceStats.first;
    auto Stats = SourceStats.second;

    Final.Addresses[Key].ReadCount += Stats.ReadCount;
    Final.Addresses[Key].WriteCount += Stats.WriteCount;
    Final.Addresses[Key].ThreadIds.insert(Stats.ThreadIds.begin(), Stats.ThreadIds.end());
  }
}


std::vector<LogStats> Handle(const std::string &LogPath) {
  const uintmax_t ThreadCount = std::thread::hardware_concurrency();
  const uintmax_t LogSize = std::filesystem::file_size(LogPath);
  const uintmax_t LogBytesPerThread = LogSize / ThreadCount;

  std::cout << "Analyzing " << LogSize << " bytes using "
            << ThreadCount << " threads..." << std::flush;

  std::vector<std::thread> Threads(ThreadCount);
  std::vector<LogStats> StatsParts(ThreadCount);

  for (uintmax_t I = 0; I < ThreadCount; ++I)
    Threads[I] = std::thread(HandleLog, LogPath, LogBytesPerThread * I,
                             LogBytesPerThread, &StatsParts[I]);
  
  auto StartTime = std::chrono::high_resolution_clock::now();

  for (auto &Thread : Threads)
    Thread.join();

  auto Duration = duration_cast<milliseconds>(high_resolution_clock::now() - StartTime);
  std::cout << ' ' << Duration.count() / 1000.0 << 's' << std::endl;

  return StatsParts;
}


LogStats Merge(std::vector<LogStats> &StatsParts) {
  LogStats FinalStats;

  std::cout << "Merging the results..." << std::flush;

  auto StartTime = std::chrono::high_resolution_clock::now();

  for (auto Part : StatsParts)
    MergeStats(FinalStats, Part);

  auto Duration = duration_cast<milliseconds>(high_resolution_clock::now() - StartTime);
  std::cout << ' ' << Duration.count() / 1000.0 << 's' << std::endl;

  return FinalStats;
}


std::string ParseArgs(const int ArgsCount,
                      const char *Args[]) {
  if (ArgsCount != 2) {
    std::cerr << "Usage: " << Args[0] << " <file>\n"
              << "Trace can be obtained using tsan-trace-analyzer-fresh "
              << "branch.\n\n"
              << "https://github.com/focs-lab/llvm-project/tree/"
              << "tsan-trace-analyzer-fresh\n";
    exit(EXIT_FAILURE);
  }

  const char *LogPath = Args[1];
  
  if (!std::filesystem::exists(LogPath)) {
    std::cerr << "Error: file '" << LogPath << "' does not exist" << std::endl;
    exit(EXIT_FAILURE);
  }

  return LogPath;
}


int main(const int ArgsCount,
         const char *Args[]) {
  std::string LogPath = ParseArgs(ArgsCount, Args);
  auto StatsParts = Handle(LogPath);
  auto FinalStats = Merge(StatsParts);

  std::vector<std::pair<AddressT, AccessStats>> AddressStatsSortRead;

  for (auto Address : FinalStats.Addresses)
    AddressStatsSortRead.push_back(Address);

  std::sort(AddressStatsSortRead.begin(), AddressStatsSortRead.end(),
            [](const std::pair<AddressT, AccessStats> &A,
               const std::pair<AddressT, AccessStats> &B) {
                return A.second.ReadCount > B.second.ReadCount;});

  std::ofstream AddressReadSortStream("address-read-sort.txt", std::ios::out);

  for (auto Address : AddressStatsSortRead) {
    auto AddressStats = Address.second;
    AddressReadSortStream << "0x" << std::hex << Address.first << std::dec << ' '
                          << AddressStats.ReadCount << ' '
                          << AddressStats.WriteCount << ' '
                          << AddressStats.ThreadIds.size() << '\n';
  }

  std::vector<std::pair<AddressT, AccessStats>> AddressStatsSortWrite;

  for (auto Address : FinalStats.Addresses)
    AddressStatsSortWrite.push_back(Address);

  std::sort(AddressStatsSortWrite.begin(), AddressStatsSortWrite.end(),
            [](const std::pair<AddressT, AccessStats> &A,
               const std::pair<AddressT, AccessStats> &B) {
                return A.second.WriteCount > B.second.WriteCount;});

  std::ofstream AddressWriteSortStream("address-write-sort.txt", std::ios::out);

  for (auto Address : AddressStatsSortWrite) {
    auto AddressStats = Address.second;
    AddressWriteSortStream << "0x" << std::hex << Address.first << std::dec << ' '
                           << AddressStats.ReadCount << ' '
                           << AddressStats.WriteCount << ' '
                           << AddressStats.ThreadIds.size() << '\n';
  }

  std::vector<std::pair<std::string, AccessStats>> SourceStatsSortRead;

  for (auto Source : FinalStats.Sources)
    SourceStatsSortRead.push_back(Source);

  std::sort(SourceStatsSortRead.begin(), SourceStatsSortRead.end(),
            [](const std::pair<const std::string, AccessStats> &A,
               const std::pair<const std::string, AccessStats> &B) {
                return A.second.ReadCount > B.second.ReadCount;});

  std::ofstream SourceReadSortStream("source-read-sort.txt", std::ios::out);

  for (auto Source : SourceStatsSortRead) {
    auto SourceStats = Source.second;
    SourceReadSortStream << "0x" << std::hex << Source.first << std::dec << ' '
                         << SourceStats.ReadCount << ' '
                         << SourceStats.WriteCount << ' '
                         << SourceStats.ThreadIds.size() << '\n';
  }

  std::vector<std::pair<std::string, AccessStats>> SourceStatsSortWrite;

  for (auto Source : FinalStats.Sources)
    SourceStatsSortWrite.push_back(Source);

  std::sort(SourceStatsSortWrite.begin(), SourceStatsSortWrite.end(),
            [](const std::pair<const std::string, AccessStats> &A,
               const std::pair<const std::string, AccessStats> &B) {
                return A.second.WriteCount > B.second.WriteCount;});

  std::ofstream SourceWriteSortStream("source-write-sort.txt", std::ios::out);

  for (auto Source : SourceStatsSortWrite) {
    auto SourceStats = Source.second;
    SourceWriteSortStream << "0x" << std::hex << Source.first << std::dec << ' '
                          << SourceStats.ReadCount << ' '
                          << SourceStats.WriteCount << ' '
                          << SourceStats.ThreadIds.size() << '\n';
  }
}
