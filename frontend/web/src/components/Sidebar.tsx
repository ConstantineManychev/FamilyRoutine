import { useState } from 'react';
import { useTranslation } from 'react-i18next';
import { useNavigate } from 'react-router-dom';
import { Settings, Calendar, Users, BookOpen, LogOut, Plus, ChevronDown } from 'lucide-react';
import { apiClient } from '../api/authService';

interface Family {
    id: string;
    name: string;
}

interface SidebarProps {
    fName: string;
    lName: string;
    families: Family[]; 
    avatarUrl?: string;
}

export const Sidebar = ({ fName, lName, families, avatarUrl }: SidebarProps) => {
    const { t } = useTranslation();
    const nav = useNavigate();
    
    const [isFamiliesOpen, setIsFamiliesOpen] = useState(false);
    const [isDictsOpen, setIsDictsOpen] = useState(false);

    const initials = (fName && lName) 
    ? `${fName.charAt(0)}${lName.charAt(0)}`.toUpperCase() 
    : fName.charAt(0).toUpperCase() || "?";

    const handleLogout = async () => {
        try {
            await apiClient.post('/api/auth/logout');
        } finally {
            nav('/auth');
        }
    };

    return (
        <aside className="w-64 h-screen bg-gray-900 text-gray-100 flex flex-col flex-shrink-0 z-50 shadow-xl select-none">
            <div className="p-6 flex flex-col items-center justify-center border-b border-gray-800">
                {avatarUrl ? (
                    <img src={avatarUrl} alt="Avatar" className="w-16 h-16 rounded-full object-cover border-2 border-gray-700" />
                ) : (
                    <div className="w-16 h-16 rounded-full bg-gradient-to-tr from-blue-600 to-blue-400 flex items-center justify-center text-xl font-bold border-2 border-gray-700">
                        {initials}
                    </div>
                )}
                <span className="mt-3 font-medium text-sm text-gray-300">{fName} {lName}</span>
            </div>

            <nav className="flex-1 overflow-y-auto py-4 scrollbar-hide">
                <ul className="space-y-1 px-2">
                    <MenuItem icon={<Settings size={20}/>} label={t('nav.settings')} onClick={() => {}} />
                    
                    <MenuItem icon={<Calendar size={20}/>} label={t('nav.schedule')} onClick={() => {}} />

                    <li className="flex flex-col">
                        <button 
                            onMouseEnter={() => setIsFamiliesOpen(true)}
                            className="flex items-center justify-between px-4 py-3 hover:bg-gray-800 rounded-lg transition-colors text-sm font-medium w-full"
                        >
                            <div className="flex items-center">
                                <Users className="mr-3 text-gray-400" size={20} />
                                <span>{t('nav.families')}</span>
                            </div>
                            <ChevronDown size={14} className={`transition-transform ${isFamiliesOpen ? 'rotate-180' : ''}`} />
                        </button>
                        
                        {isFamiliesOpen && (
                            <ul className="mt-1 ml-4 border-l border-gray-700 space-y-1" onMouseLeave={() => setIsFamiliesOpen(false)}>
                                {families.map(family => (
                                    <SubMenuItem key={family.id} label={family.name} />
                                ))}
                                <button className="flex items-center w-full px-4 py-2 text-xs text-blue-400 hover:text-blue-300 font-semibold transition-colors">
                                    <Plus size={14} className="mr-2" />
                                    {t('nav.createFamily')}
                                </button>
                            </ul>
                        )}
                    </li>

                    <li className="flex flex-col">
                        <button 
                            onMouseEnter={() => setIsDictsOpen(true)}
                            className="flex items-center justify-between px-4 py-3 hover:bg-gray-800 rounded-lg transition-colors text-sm font-medium w-full"
                        >
                            <div className="flex items-center">
                                <BookOpen className="mr-3 text-gray-400" size={20} />
                                <span>{t('nav.dicts')}</span>
                            </div>
                            <ChevronDown size={14} className={`transition-transform ${isDictsOpen ? 'rotate-180' : ''}`} />
                        </button>
                        
                        {isDictsOpen && (
                            <ul className="mt-1 ml-4 border-l border-gray-700 space-y-1" onMouseLeave={() => setIsDictsOpen(false)}>
                                <SubMenuItem label={t('nav.items')} />
                                <SubMenuItem label={t('nav.events')} />
                                <SubMenuItem label={t('nav.currencies')} />
                            </ul>
                        )}
                    </li>
                </ul>
            </nav>

            <div className="p-4 border-t border-gray-800">
                <button 
                    onClick={handleLogout}
                    className="w-full flex items-center justify-center px-4 py-2.5 bg-red-500/10 text-red-400 hover:bg-red-500/20 rounded-lg transition-colors text-sm font-medium"
                >
                    <LogOut className="w-5 h-5 mr-2" />
                    <span>{t('nav.logout')}</span>
                </button>
            </div>
        </aside>
    );
};

const MenuItem = ({ icon, label, onClick }: { icon: React.ReactNode, label: string, onClick: () => void }) => (
    <li>
        <button onClick={onClick} className="w-full flex items-center px-4 py-3 hover:bg-gray-800 rounded-lg transition-colors text-sm font-medium">
            <span className="mr-3 text-gray-400">{icon}</span>
            <span>{label}</span>
        </button>
    </li>
);

const SubMenuItem = ({ label }: { label: string }) => (
    <li>
        <button className="w-full text-left px-4 py-2 hover:bg-gray-800 rounded-lg transition-colors text-xs text-gray-400 hover:text-gray-100">
            {label}
        </button>
    </li>
);