#!/bin/bash

#----------------------------- fetch system details ----------------------------------------------
echo "*****************************************************************************"
bios=$(dmidecode -t bios | grep Version | awk '{print $2}')
microcode=$(grep micro /proc/cpuinfo | uniq | awk '{print $3}')
operating_system=$(awk -F '"' '/PRETTY_NAME=/{print $2}' /etc/os-release)
kernel=$(uname -r)
memory_speed=$(dmidecode -t 17 | grep Speed | head -n 1 | awk '{print $2}')
threads_per_core=$(lscpu | awk '/Thread\(s\) per core:/{print $NF}')
total_sockets=$(lscpu | awk '/Socket\(s\):/{print $NF}')
cores_per_socket=$(lscpu | awk '/Core\(s\) per socket:/{print $NF}')
no_of_numa_nodes=$(lscpu | awk '/NUMA node\(s\):/{print $NF}')
physical_cores_per_numa=$(( $cores_per_socket / $(( $no_of_numa_nodes / $total_sockets ))))
total_numa_nodes=$(lscpu | grep -c "NUMA node.* CPU(s):")
procs=$(cat /proc/cpuinfo | grep -c processor)
total_cores=$((cores_per_socket*total_sockets))
model=$(lscpu | awk '/Model:/{print $NF}')
family=$(lscpu | awk '/CPU family:/{print $NF}')
stepping=$(lscpu | awk '/Stepping:/{print $NF}')
total_numa_nodes=$(lscpu | awk  '/NUMA node\(s\):/{print $NF}')
cores_per_die=$(echo "scale=0; $cores_per_socket/4" | bc)
cores_per_node=$((total_cores/total_numa_nodes))
LAMMPS_LATEST="v1.0.2"
GROMACS_LATEST="v1.0.1"
#1st change
CloverLeaf_LATEST="v1.0.2"
dtimeout=5
hostname=`cat /etc/hostname`

echo -e "Total socket               :" ${total_sockets}
echo -e "Total numa nodes           :" ${no_of_numa_nodes}
echo -e "Total cores                :" ${total_cores}
echo -e "Threads per core           :" ${threads_per_core}
echo -e "Physical Cores per socket  :" ${cores_per_socket}
echo -e "Physical cores per numa    :" ${physical_cores_per_numa}
echo "*****************************************************************************"

#---------------------------------------------------------------------------------------------------

base_cmd="docker run -it --privileged --shm-size=4gb ger-is-registry.caas.intel.com/tce-hpc-containers/"

valid_workloads=(hpcg_cts snap_cts laghos_cts quicksilver_cts hpcg_xroads snap_xroads pennant_xroads minipic_xroads umt_xroads vpic_xroads lammps_protein gromacs_ion_channel openfoam_motorbike cloverleaf_timesteps)

#---------------------------------------- FUNCTIONS ------------------------------------------------
print_usage(){
    echo -e "\nUsage_ bash $0 -m/--workload <workload> -e/--emon <yes> -S/--session\n

        workload     : <string> one of supported HPC workload to run \n\
        emon         : <yes> Collect emon metrics along with the runs\n\
        session      : <string> Provide a tag or hint about the experiment being run so it will be recoded in the results dir & summary csv (avoid string with space)\n\
        "

    echo -e "Valid options for -m/--workload\n
    \tall"
    for workload in ${valid_workloads[@]}
    do 
      echo -e "\t$workload"
    done 
    echo -e "\n"
}

#---------------------------------------- ARG PARSE -------------------------------------------------
while [ $# -gt 0 ]; do
   case "$1" in
        --help | -h)
            print_usage
            exit 0 ;;
        --workload | -m)
            workload=$2 ;;
        --emon | -e)
            collect_emon=$2 ;;
        --session | -S)
            session_tag=$2 ;;
          *)
      echo -e "\nInvalid option: "$1""
      print_usage
      exit 1;;
   esac
   shift 2
done

if [[ -z $workload ]];then
    workloads=${valid_workloads[@]}
elif [[ $workload == "all" ]]; then 
    workloads=${valid_workloads[@]}
else
    workloads=$workload
fi

session_ts=$(date +%m%d%Y%H%M%S)
if [ -z $session_tag ]; then 
    session_name=${workload}_${session_ts}
else
    session_name=${session_tag}_${workload}_${session_ts}
fi

result_dir="$(pwd)/results/hpc_numa${total_numa_nodes}_${session_name}" && mkdir -p ${result_dir}

# ------------------------------ EMON SETTINGS -----------------------------------
if [ -z $collect_emon ]; then 
    collect_emon=0
    process_emon=0
else
    collect_emon=1
    process_emon=1
fi
begin_sample=1
dirty_samples=1
emon_data="0"
emon_dir="$(pwd)/emon"
sep_dir="/opt/intel/sep"
edp_dir="${sep_dir}/config/edp"
emon_csv_file="__edp_socket_view_summary.csv"

#---------------------------- EVENT FILE --------------------------------------
if [[ ${model} == "207" ]]; then
    event_file="/opt/intel/sep/config/edp/emeraldrapids_server_events_private.txt"
elif [[ ${model} == "173" ]]; then
    event_file="/opt/intel/sep/config/edp/graniterapids_server_events_private.txt"
else
    echo "Model is not recognized"
    exit 1
fi
#model=$(lscpu | awk '/Model:/{print $NF}')
#[1;5B
# ------------------------------ VALIDATE EMON SETTINGS -----------------------------------
if [[ $collect_emon -eq 1 ]];then
    collect_emon=$(bash ../misc/check_emon_setup.sh) || exit 1
    collect_emon=$(echo ${collect_emon} | awk '{print $NF}')
fi

summary_file=$(pwd)/hpc_results.csv
#----------------------------------------------------------------------------------------
echo "performance" | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor

summary_header="Start,End,Session,Hostname,Bios,Microcode,Operating System,Kernel,Memory Speed,Total Numa Nodes,Workload,Result Type,Result,Metric,dcso metric link"
# ------------------------------ START EMON COLLECTION -----------------------------------
if [ ${collect_emon} -eq 1 ]; then
    summary_header="$summary_header,EmonData"
    [ -d ${emon_dir} ] || mkdir -p ${emon_dir}
else
    echo -e "Note, HPC tests will be run without Emon collection..!\n"
fi

if [[ ! -f ${summary_file} ]]; then
    echo $summary_header > $summary_file
fi


last_emon_data=""
start_time=$(date "+%D %T")
end_time=$(date "+%D %T")
run_test(){
    
    local command=$1
    local session=$2
    local fl_name=$3
    if [ ${collect_emon} -eq 1 ]; then
        last_emon_data=""
        killall emon
        source "${sep_dir}/sep_vars.sh"
        emon -collect-edp > ${emon_dir}/emon_${fl_name}.dat &
    fi
    start_time=$(date "+%D %T")
    eval $command
    end_time=$(date "+%D %T")
    # ------------------------------ PROCESS AND PARSE EMON -----------------------------------
    if [[ ${process_emon} -eq 1 && ${collect_emon} -eq 1 ]]; then
        killall emon      
        output_dir="${emon_dir}/${session}/${fl_name}"
        mkdir -p ${output_dir}

        edp_xml_file=$(awk -F':' '/EDP metric file/{print $NF}' ${emon_dir}/emon_${fl_name}.dat)
        edp_chart_file=$(awk -F':' '/EDP chart file/{print $NF}' ${emon_dir}/emon_${fl_name}.dat)
        total_samples=$(cat ${emon_dir}/emon_${fl_name}.dat | grep -c INST_RETIRED.ANY)
        end_sample=$((total_samples-dirty_samples))
        FreeMEM=$(free -m | head -2 | tail -1 | awk '{ print $4 }')
        FreeMEM=$(( $FreeMEM - 1024 ))
        jruby_options="-J-Xmx${FreeMEM}m -J-Xms${FreeMEM}m"
        jruby ${jruby_options} ${edp_dir}/edp.rb -i ${emon_dir}/emon_${fl_name}.dat -f ${edp_dir}/${edp_chart_file} -m  ${edp_dir}/${edp_xml_file} -o ${output_dir}/${fl_name} -b ${begin_sample} -e ${end_sample} --socket-view  -p $(( total_cores * 3/4 ))
        if [[ ${emon_csv_file} == "__edp_socket_view_summary.csv" ]]; then 
            read emon_data < <(../misc/read_emon_socket_view.sh ${emon_csv_file})
        else
            read emon_data < <(../misc/read_emon.sh ${emon_csv_file})
        fi
        mv ${emon_dir}/emon_${fl_name}.dat ${output_dir}/
        mv __edp_* ${output_dir}/
        last_emon_data="$(hostname):${emon_dir}/${fl_name}/${emon_csv_file},${emon_data}"
    fi
}


run_cts_hpcg(){
    local workload=$1  
    local fl_name=$2
    local logfile=$3
    local container=$4

    command="docker run -it --privileged -e NCORES=$total_cores --shm-size=4gb ${container}"
    run_test "$command | tee -a $logfile" $session_name $fl_name
    result=$(awk '/real/{printf $NF}' ${logfile} | tr '\r' ' ')
    summary="$start_time,$end_time,$session_name,$bios,$microcode,$operating_system,$kernel,$memory_speed,$total_numa_nodes,\"CTS HPCG\",\"Wall Time\",$result,\"seconds\""
    if [ $process_emon -eq 1 ]; then 
        summary="$summary,$last_emon_data"
    fi
    echo $summary >> $summary_file        
}


run_xroads_hpcg(){
    local workload=$1  
    local fl_name=$2
    local logfile=$3
    local container=$4
    
    command="docker run -it --privileged -e NCORES=$total_cores --shm-size=4gb ${container}"
    run_test "$command | tee -a $logfile" $session_name $fl_name
    result=$(awk '/HPCG result is VALID with a GFLOP/{printf $NF}' ${logfile} | tr '\r' ' ')
    summary="$start_time,$end_time,$session_name,$bios,$microcode,$operating_system,$kernel,$memory_speed,$total_numa_nodes,\"XROADS HPCG\",\"Flops\",$result,\"GFlops/sec\""
    if [ $process_emon -eq 1 ]; then 
        summary="$summary,$last_emon_data"
    fi
    echo $summary >> $summary_file        
}

run_xroads_minipic(){
    local workload=$1  
    local fl_name=$2
    local logfile=$3
    local container=$4
    
    command="docker run -it --privileged -e NCORES=$total_cores --shm-size=4gb ${container}"
    run_test "$command | tee -a $logfile" $session_name $fl_name
    result=$(awk '/Move time/{getline}END{printf $3}' ${logfile} | tr '\r' ' ')
    summary="$start_time,$end_time,$session_name,$bios,$microcode,$operating_system,$kernel,$memory_speed,$total_numa_nodes,\"XROADS Minipic\",\"Throughput\",$result,\"updates/sec\""
    if [ $process_emon -eq 1 ]; then 
        summary="$summary,$last_emon_data"
    fi
    echo $summary >> $summary_file        
}

run_xroads_pennant(){
    local workload=$1  
    local fl_name=$2
    local logfile=$3
    local container=$4
    
    command="docker run -it --privileged -e NCORES=$total_cores --shm-size=4gb ${container}"
    run_test "$command | tee -a $logfile" $session_name $fl_name
    result=$(grep "FOM hydro cycle run time" -A 2 $logfile | awk '{printf $NF}'  | tr '\r' ' ' | xargs)
    summary="$start_time,$end_time,$session_name,$bios,$microcode,$operating_system,$kernel,$memory_speed,$total_numa_nodes,\"XROADS Pennant\",\"Hydro cycle run time\",$result,\"secs\""
    if [ $process_emon -eq 1 ]; then 
        summary="$summary,$last_emon_data"
    fi
    echo $summary >> $summary_file        
}

run_cts_snap(){
    local workload=$1  
    local fl_name=$2
    local logfile=$3
    local container=$4
    container_count=$(docker ps -a | grep -c -w cts_snap)
    if [[ $container_count -gt 0 ]]; then
        docker stop cts_snap
        docker rm cts_snap
    fi
    run_cmd="docker run -itd --rm --privileged --name cts_snap --shm-size=4gb ${container} bash"
    eval $run_cmd
    echo "
        sed -i 's/npez=112/npez=$total_cores/' CTS2_SNAP_112core_v0.input
        sed -i 's/nz=448/nz=$(($total_cores * 4))/' CTS2_SNAP_112core_v0.input
        sed -i 's/mpi_ranks=112/mpi_ranks=$total_cores/' run
        bash run
    " > run_cmd.sh
    docker cp run_cmd.sh cts_snap:/Run/run_cmd.sh
    command="docker exec -it cts_snap bash /Run/run_cmd.sh"
    run_test "$command | tee -a $logfile" $session_name $fl_name
    result=$(awk '/Grind Time \(nanoseconds\)/{printf $NF}' ${logfile} | tr '\r' ' ')
    summary="$start_time,$end_time,$session_name,$bios,$microcode,$operating_system,$kernel,$memory_speed,$total_numa_nodes,\"CTS SNAP\",\"Grind Time\",$result,\"nano seconds\""
    if [ $process_emon -eq 1 ]; then 
        summary="$summary,$last_emon_data"
    fi
    echo $summary >> $summary_file        
}

run_xroads_snap(){
    local workload=$1  
    local fl_name=$2
    local logfile=$3
    local container=$4

    container_count=$(docker ps -a | grep -c -w xroads_snap)
    if [[ $container_count -gt 0 ]]; then
        docker stop xroads_snap
        docker rm xroads_snap
    fi
    run_cmd="docker run -itd --rm --privileged --name xroads_snap --shm-size=4gb ${container} bash"
    eval $run_cmd
    echo "
        sed -i 's/npez=112/npez=$total_cores/' input/inh0001t1
        sed -i 's/nz=448/nz=$(($total_cores * 4))/' input/inh0001t1
        sed -i 's/NP=112/NP=$total_cores/' hwr_run.mps
        sed -i 's/PPN=112/PPN=$total_cores/' hwr_run.mps
        bash hwr_run.mps \$PWD \$PWD
    " > run_cmd.sh
    docker cp run_cmd.sh xroads_snap:/Run/run_cmd.sh
    command="docker exec -it xroads_snap bash /Run/run_cmd.sh"
    run_test "$command | tee -a $logfile" $session_name $fl_name
    result=$(grep 'Performance metric' ${logfile} | awk '/Performance metric\: LB/{getline}END{printf $4}' | tr '\r' ' ')
    summary="$start_time,$end_time,$session_name,$bios,$microcode,$operating_system,$kernel,$memory_speed,$total_numa_nodes,\"XROADS SNAP\",\"Performance metric LB\",$result,\"seconds\""
    if [ $process_emon -eq 1 ]; then 
        summary="$summary,$last_emon_data"
    fi
    echo $summary >> $summary_file        
}

run_xroads_vpic(){
    local workload=$1  
    local fl_name=$2
    local logfile=$3
    local container=$4
    if [[ $total_cores -ne 112 ]] || [[ $total_sockets -ne 2 ]] ; then
        echo -e "This workload enabled onlyfor 56c SPR systems, its not currently supported on other core count or non-2s setups."
        return
    fi
    command="docker run -it --privileged --shm-size=4gb ${container}"
    run_test "$command | tee -a $logfile" $session_name $fl_name
    result=$(grep '*** Done' ${logfile} | awk '/*** Done \(/{getline}END{printf $3}' | tr '\r' ' ' | tr '(' ' ')
    summary="$start_time,$end_time,$session_name,$bios,$microcode,$operating_system,$kernel,$memory_speed,$total_numa_nodes,\"XROADS VPIC\",\"Wall Time\",$result,\"seconds\""
    if [ $process_emon -eq 1 ]; then 
        summary="$summary,$last_emon_data"
    fi
    echo $summary >> $summary_file        
}


run_xroads_umt(){
    local workload=$1  
    local fl_name=$2
    local logfile=$3
    local container=$4
    if [[ $total_cores -ne 112 ]] || [[ $total_sockets -ne 2 ]] ; then
        echo -e "This workload enabled only for 56c SPR 2S systems, its not currently supported on other core count or non-2s setups."
        return
    fi
    command="docker run -it --privileged --shm-size=4gb ${container}"
    echo $command
    run_test "$command | tee -a $logfile" $session_name $fl_name
    result=$(grep 'numzones: 3x3x4' -A 1 ${logfile} | awk '/figure of merit/{getline}END{printf $NF}' | tr '\r' ' ')
    summary="$start_time,$end_time,$session_name,$bios,$microcode,$operating_system,$kernel,$memory_speed,$total_numa_nodes,\"XROADS UMT\",\"FOM (3x3x4)\",$result,\"seconds\""
    if [ $process_emon -eq 1 ]; then 
        summary="$summary,$last_emon_data"
    fi
    echo $summary >> $summary_file
    result=$(grep 'numzones: 4x4x4' -A 1 ${logfile} | awk '/figure of merit/{getline}END{printf $NF}' | tr '\r' ' ')
    summary="$start_time,$end_time,$session_name,$bios,$microcode,$operating_system,$kernel,$memory_speed,$total_numa_nodes,\"XROADS UMT\",\"FOM (4x4x4)\",$result,\"seconds\""
    if [ $process_emon -eq 1 ]; then 
        summary="$summary,$last_emon_data"
    fi
    echo $summary >> $summary_file    
}

run_cts_laghos(){
    local workload=$1  
    local fl_name=$2
    local logfile=$3
    local container=$4
    if [[ $total_cores -ne 112 ]] || [[ $total_sockets -ne 2 ]] ; then
        echo -e "This workload enabled only for 56c SPR 2S systems, its not currently supported on other core count or non-2s setups."
        return
    fi
    command="docker run -it --privileged --shm-size=4gb ${container}"
    echo $command
    run_test "$command | tee -a $logfile" $session_name $fl_name
    declare -a kpis=(
        "CG (H1) rate > megadofs x cg_iterations / second"
        "Forces rate > megadofs x timesteps / second"
        "UpdateQuadData rate > megaquads x timesteps / second"
        "Major kernels total rate >megadofs x time steps / second")
    for j in "${kpis[@]}"; do
        kpi_name=$(echo $j | cut -d ">" -f 1)
        kpi_metric=$(echo $j | cut -d ">" -f 2)
        result=$(grep -A 16 "FOM for the 3 runs" ${logfile} | grep "$kpi_name" | awk '{ sum += $NF } END { if (NR > 0) print sum / NR }')
        summary="$start_time,$end_time,$session_name,$bios,$microcode,$operating_system,$kernel,$memory_speed,$total_numa_nodes,\"XROADS VPIC\",\"$kpi_name\",$result,\"$kpi_metric\""
        if [ $process_emon -eq 1 ]; then 
            summary="$summary,$last_emon_data"
        fi
        echo $summary >> $summary_file        
    done
}

run_cts_quicksilver(){
    local workload=$1  
    local fl_name=$2
    local logfile=$3
    local container=$4
    if [[ $total_cores -ne 112 ]] || [[ $total_sockets -ne 2 ]] ; then
        echo -e "This workload enabled onlyfor 56c SPR systems, its not currently supported on other core count or non-2s setups."
        return
    fi
    command="docker run -it --privileged --shm-size=4gb ${container}"
    run_test "$command | tee -a $logfile" $session_name $fl_name

    for i in 1 2; do 
        result=$(grep -m $i 'Figure Of Merit' ${logfile} | awk '/Figure Of Merit/{getline}END{printf $4}' | tr '\r' ' ' | tr '(' ' ')
        summary="$start_time,$end_time,$session_name,$bios,$microcode,$operating_system,$kernel,$memory_speed,$total_numa_nodes,\"CTS QuickSilver\",\"Figure of Merit $i OMP\",$result,\"Num Segments / Cycle Tracking Time\""
        if [ $process_emon -eq 1 ]; then 
            summary="$summary,$last_emon_data"
        fi
        echo $summary >> $summary_file
    done
}

run_lammps_protein(){
    local container=$4

    docker rm lammps > /dev/null 2>&1
    docker run -itd --privileged --shm-size=4gb --name lammps ${container} bash
    exe_command="docker exec lammps /bin/bash /home/lammps/lammps 10"
    if [ ${collect_emon} -eq 1 ]; then
        [[ ! -f ~/.ssh/known_hosts ]] && touch ~/.ssh/known_hosts
        killall emon sar iostat vmstat
        source "${sep_dir}/sep_vars.sh"
	tmc_cmd='tmc -c "${exe_command}" -e ${event_file} -a "lammps_protein" -i "${model}_${bios}_${kernel}" -G WW$(date +%W) -u -n '
	eval $tmc_cmd 2>&1 | tee $logfile
    else
        eval ${exe_command} 2>&1 | tee $logfile
    fi

    result=$(grep "Average Performance (Timesteps):" $logfile | awk '{printf $4}')
    cpu_use=$(grep "Average CPU use (%):" $logfile | awk '{printf $5}')
    dcso_link=$(grep "Metrics Record -" $logfile | awk '{printf $9}')
    summary="$start_time,$end_time,$session_name,$hostname,$bios,$microcode,$operating_system,$kernel,$memory_speed,$total_numa_nodes,\"LAMMPS Protein\",\"10-loop average performance\",$result,\"Timesteps\""
    if [ ${collect_emon} -eq 1 ]; then
        summary="$summary,$dcso_link"
    fi
    echo $summary >> $summary_file

    echo "lammps_protein Average Performance Timesteps: ${result}"
    echo "lammps_protein Average CPU Usage percentage: ${cpu_use}"
}


run_cloverleaf_timescale(){
    local container=$4

    docker rm cloverleaf > /dev/null 2>&1
    docker run -itd --privileged --shm-size=4gb --name cloverleaf ${container} bash
    exe_command="docker exec cloverleaf /bin/bash /home/cloverleaf/cloverleaf 10"
    if [ ${collect_emon} -eq 1 ]; then
        [[ ! -f ~/.ssh/known_hosts ]] && touch ~/.ssh/known_hosts
        killall emon sar iostat vmstat
        source "${sep_dir}/sep_vars.sh"
	tmc_cmd='tmc -c "${exe_command}" -e ${event_file} -a "cloverleaf_timescale" -i "${model}_${bios}_${kernel}" -G WW$(date +%W) -u -n '
	eval $tmc_cmd 2>&1 | tee $logfile
    else
        eval ${exe_command} 2>&1 | tee $logfile
    fi
    result=$(grep "Average Performance (Timesteps):" $logfile | awk '{printf $4}')
    cpu_use=$(grep "Average CPU use (%):" $logfile | awk '{printf $5}')
    dcso_link=$(grep "Metrics Record -" $logfile | awk '{printf $9}')
    summary="$start_time,$end_time,$session_name,$hostname,$bios,$microcode,$operating_system,$kernel,$memory_speed,$total_numa_nodes,\"CloverLeaf Timescale\",\"10-loop average performance\",$result,\"Timesteps\""
    if [ ${collect_emon} -eq 1 ]; then
        summary="$summary,$dcso_link"
    fi
    echo $summary >> $summary_file

    echo "cloverleaf_timescale Average Performance Timesteps: ${result}"
    echo "cloverleaf_timescale Average CPU Usage percentage: ${cpu_use}"
}



run_gromacs_ion_channel(){
    local container=$4

    docker rm gromacs > /dev/null 2>&1
    docker run -itd --privileged --shm-size=4gb --name gromacs ${container} bash
    exe_command="docker exec gromacs /bin/bash /home/gromacs/run_ion_channel 10000"
    if [ ${collect_emon} -eq 1 ]; then
        [[ ! -f ~/.ssh/known_hosts ]] && touch ~/.ssh/known_hosts
        killall emon sar iostat vmstat
        source "${sep_dir}/sep_vars.sh"
        tmc_cmd='tmc -c "${exe_command}" -e ${event_file} -a "gromacs_ion_channel" -i "${model}_${bios}_${kernel}" -G WW$(date +%W) -u -n '
        eval $tmc_cmd 2>&1 | tee $logfile
    else
        eval ${exe_command} 2>&1 | tee $logfile
    fi

    result=$(grep -A 1 "Steps" $logfile | tail -1 | awk -F',' '{print $3}')
    dcso_link=$(grep "Metrics Record -" $logfile | awk '{printf $9}')
    summary="$start_time,$end_time,$session_name,$hostname,$bios,$microcode,$operating_system,$kernel,$memory_speed,$total_numa_nodes,\"GROMACS Ion Channel\",\"Wall Time\",$result,\"seconds\""
    if [ ${collect_emon} -eq 1 ]; then
        summary="$summary,$dcso_link"
    fi
    echo $summary >> $summary_file

    echo "gromacs_ion_channel Wall Time Sec: ${result}"
}

run_openfoam_motorbike(){
    local container=$4

    docker rm openfoam > /dev/null 2>&1
    docker run -itd --privileged --shm-size=4gb --name openfoam ${container} bash
    exe_command="docker exec openfoam /bin/bash /home/run_motorbike"
    if [ ${collect_emon} -eq 1 ]; then
        [[ ! -f ~/.ssh/known_hosts ]] && touch ~/.ssh/known_hosts
        killall emon sar iostat vmstat
        source "${sep_dir}/sep_vars.sh"
        tmc_cmd='tmc -c "${exe_command}" -e ${event_file} -a "openfoam_motorbike" -i "${model}_${bios}_${kernel}" -G WW$(date +%W) -u -n '
        eval $tmc_cmd 2>&1 | tee $logfile
    else
        eval ${exe_command} 2>&1 | tee $logfile
    fi

    result=$( grep Clocktime $logfile | awk '{print $3}')
    dcso_link=$(grep "Metrics Record -" $logfile | awk '{printf $9}')
    summary="$start_time,$end_time,$session_name,$hostname,$bios,$microcode,$operating_system,$kernel,$memory_speed,$total_numa_nodes,\"OpenFOAM Motorbike\",\"Clock Time\",$result,\"seconds\""
    if [ ${collect_emon} -eq 1 ]; then
        summary="$summary,$dcso_link"
    fi
    echo $summary >> $summary_file

    echo "openfoam_motorbike Final Clocktime Sec: ${result}"
}


prepare_and_run_test(){
    local workload=$1
    fl_name="${session_name}_${total_numa_nodes}numas_hpc_${workload}"
    logfile="${result_dir}/result_${fl_name}.txt"
    tag=$(echo $workload | tr "_" ":")
    container="ger-is-registry.caas.intel.com/tce-hpc-containers/${tag}"

    if [[ "$workload" == "hpcg_cts" ]];then
        echo "Will be running $workload..."
        run_cts_hpcg $workload $fl_name $logfile $container

    elif [[ "$workload" == "hpcg_xroads" ]];then
        echo "Will be running $workload..."
        run_xroads_hpcg $workload $fl_name $logfile $container

    elif [[ "$workload" == "laghos_cts" ]];then
        echo "Will be running $workload..."
        run_cts_laghos $workload $fl_name $logfile $container
    elif [[ "$workload" == "snap_cts" ]];then
        echo "Will be running $workload..."
        run_cts_snap $workload $fl_name $logfile $container

    elif [[ "$workload" == "pennant_xroads" ]];then
        echo "Will be running $workload..."
        run_xroads_pennant $workload $fl_name $logfile $container

    elif [[ "$workload" == "minipic_xroads" ]];then
        echo "Will be running $workload..."
        run_xroads_minipic $workload $fl_name $logfile $container

    elif [[ "$workload" == "quicksilver_cts" ]];then
        echo "Will be running $workload..."
        run_cts_quicksilver $workload $fl_name $logfile $container

    elif [[ "$workload" == "snap_xroads" ]];then
        echo "Will be running $workload..."
        run_xroads_snap $workload $fl_name $logfile $container

    elif [[ "$workload" == "umt_xroads" ]];then
        echo "Will be running $workload..."
        run_xroads_umt $workload $fl_name $logfile $container

    elif [[ "$workload" == "vpic_xroads" ]];then
        echo "Will be running $workload..."
        run_xroads_vpic $workload $fl_name $logfile $container

    elif [[ "$workload" == "lammps_protein" ]];then
        echo "Will be running $workload..."
        container="dcsorepo.jf.intel.com/hero-features/hpc_lammps:${LAMMPS_LATEST}"
        run_lammps_protein $workload $fl_name $logfile $container

    elif [[ "$workload" == "gromacs_ion_channel" ]];then
        echo "Will be running $workload..."
        container="dcsorepo.jf.intel.com/hero-features/gromacs_container:${GROMACS_LATEST}"
        run_gromacs_ion_channel $workload $fl_name $logfile $container

                         #begin modified_CloverLeaf
    elif [[ "$workload" == "cloverleaf_timescale" ]];then
        echo "Will be running $workload..."
        container="dcsorepo.jf.intel.com/hero-features/hpc_cloverleaf:${GROMACS_LATEST}"
        run_cloverleaf_timescale $workload $fl_name $logfile $container
	                #end

    elif [[ "$workload" == "openfoam_motorbike" ]];then
        echo "Will be running $workload..."
        container="dcsorepo.jf.intel.com/hero-features/hpc_openfoam-motorbike:latest"
        run_openfoam_motorbike $workload $fl_name $logfile $container

    else
        echo -e "\nError: Invalid workload '$workload' \n\nInfo: Valid modes are: "${valid_workloads[@]}" all"
        print_usage
        exit 1
    fi
}
for testmode in $workloads; do
    echo $testmode
    prepare_and_run_test $testmode
done

echo -e  "\n******************************************************************************************************"
echo "Completed running HPC workloads. Results are copied under: ${result_dir}"
echo -e  "******************************************************************************************************\n"
